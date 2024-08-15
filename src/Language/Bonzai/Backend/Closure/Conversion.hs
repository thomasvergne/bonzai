module Language.Bonzai.Backend.Closure.Conversion where
import qualified Language.Bonzai.Syntax.MLIR as MLIR
import qualified Data.Set as Set
import qualified GHC.IO as IO
import qualified Language.Bonzai.Backend.Closure.Free as M
import qualified Data.Map as Map

{-# NOINLINE natives #-}
natives :: IORef (Map Text Int)
natives = IO.unsafePerformIO $ newIORef mempty

{-# NOINLINE lambdaCount #-}
lambdaCount :: IORef Int
lambdaCount = IO.unsafePerformIO $ newIORef 0

freshLambda :: MonadIO m => Text -> m Text
freshLambda prefix = do
  modifyIORef' lambdaCount (+1)
  n <- readIORef lambdaCount
  pure $ "@@lambda_" <> prefix <> show n

{-# NOINLINE globals #-}
globals :: IORef (Map Text Int)
globals = IO.unsafePerformIO $ newIORef mempty

-- | CLOSURE CONVERSION
-- | Closure conversion may be one of the most important steps in the
-- | compilation process. It converts all anonymous functions and closures
-- | into named functions. This is done by creating a new function that
-- | carries an environment (contains all the free variables) and a reference
-- | to the original function.
-- |
-- | - All remaining closures should converted to named functions.
-- |
-- | - When encountering a native function or global variable, it should be
-- |   added to the reserved stack, meaning that we shall not convert this 
-- |   function. However, if the function is used as a variable name in a 
-- |   call, it should be semi-converted.
-- |
-- | - Local stack is used to prevent name conflicts between reserved and locals
-- |   variables. They're defined as a set of text containing the names of the 
-- |   variables encountered in a block scope.
-- |
-- | - Special functions should not be converted, this especially includes 
-- |   ADTs. They're recognized by a special and unique character at the 
-- |   beginning of their name.
-- | 
-- | The conversion process is done by traversing the AST and converting each
-- | expression and statement into a closed expression or statement.
-- | When encountering a closure, the following algorithm is applied:
-- |
-- | - The free variables are calculated, to determine the environment.
-- |
-- | - Reserved functions are eliminated from environment, except for those
-- |   that are used as variables in the closure.
-- |
-- | - A new environment dictionary is created, containing all the free
-- |   variables (e.g. { x: x, y: y }).
-- |
-- | - A new environment variable is created, representing the closure
-- |   environment.
-- |
-- | - The body of the closure is substituted with the environment dictionary
-- |   and the closure environment variable.
-- |
-- | - The closure is converted into a named function, containing the
-- |   environment as the first argument and the rest of the arguments.
-- |
-- | - A new object (resp. dictionary) is created, containing the closure's
-- |   environment and the function reference (e.g. { f: <func>, env: <env> }).
convert :: MonadIO m => MLIR.Expression -> m MLIR.Expression
convert (MLIR.MkExprVariable x) = do
  globals' <- readIORef globals
  natives' <- readIORef natives
  let reserved = globals' <> natives'
  case Map.lookup x reserved of
    Just arity -> do
      let args = take arity $ map (\n -> "arg" <> show n) [(0 :: Integer)..]

      pure $ MLIR.MkExprLambda args (MLIR.MkExprApplication (MLIR.MkExprVariable x) (map MLIR.MkExprVariable args))

    Nothing -> pure $ MLIR.MkExprVariable x
convert (MLIR.MkExprLiteral x) = pure $ MLIR.MkExprLiteral x
convert (MLIR.MkExprFunction f args b) = do
  modifyIORef' globals (Map.insert f (length args))
  MLIR.MkExprFunction f args <$> convert b
convert (MLIR.MkExprLambda args body) = do
  let freeVars = M.free body
  nativesFuns <- readIORef natives
  let finalNativesFuns = Map.keysSet nativesFuns Set.\\ Set.fromList args

  let env = freeVars Set.\\ (finalNativesFuns <> Set.fromList args)
      envAsList = Set.toList env
      dict = MLIR.MkExprList $ map MLIR.MkExprVariable envAsList
  
  let prefixBody = zipWith (\n i -> do
          MLIR.MkExprLet n (MLIR.MkExprIndex (MLIR.MkExprVariable "env") (MLIR.MkExprLiteral (MLIR.MkLitInt i)))
        ) envAsList [0..]

  body' <- convert body

  let finalBody = case body' of
          MLIR.MkExprBlock es -> MLIR.MkExprBlock $ prefixBody <> es
          e -> MLIR.MkExprBlock $ prefixBody <> [e]

  pure (MLIR.MkExprList [
      MLIR.MkExprLambda args finalBody,
      dict
    ])
convert (MLIR.MkExprApplication f args) = do
  globals' <- readIORef globals
  natives' <- readIORef natives
  
  let reserved = globals' <> natives'

  args' <- mapM convert args

  case f of
    MLIR.MkExprVariable x | Map.member x reserved -> 
      pure $ MLIR.MkExprApplication (MLIR.MkExprVariable x) args'
    _ -> do
      name <- freshLambda "call"
      f' <- convert f

      let callVar = MLIR.MkExprVariable name
      let function = MLIR.MkExprIndex callVar (MLIR.MkExprLiteral (MLIR.MkLitInt 0))
      let env = MLIR.MkExprIndex callVar (MLIR.MkExprLiteral (MLIR.MkLitInt 1))

      let call = MLIR.MkExprApplication function (env : args')

      pure $ MLIR.MkExprUnpack name f' call
convert (MLIR.MkExprLet x e) = MLIR.MkExprLet x <$> convert e
convert (MLIR.MkExprMut x e) = MLIR.MkExprMut x <$> convert e
convert (MLIR.MkExprList xs) = MLIR.MkExprList <$> mapM convert xs
convert (MLIR.MkExprTernary c t e) = MLIR.MkExprTernary <$> convert c <*> convert t <*> convert e
convert (MLIR.MkExprUpdate u e) = MLIR.MkExprUpdate <$> convertUpdate u <*> convert e
convert (MLIR.MkExprBlock es) = MLIR.MkExprBlock <$> mapM convert es
convert (MLIR.MkExprEvent es) = MLIR.MkExprEvent <$> mapM convert es
convert (MLIR.MkExprOn ev args e) = do
  e' <- convert e

  pure $ MLIR.MkExprOn ev args e'
convert (MLIR.MkExprSend e ev es) = MLIR.MkExprSend <$> convert e <*> pure ev <*> mapM convert es
convert (MLIR.MkExprSpawn e) = MLIR.MkExprSpawn <$> convert e
convert (MLIR.MkExprNative n ty) = do
  let arity = case ty of
        args MLIR.:->: _ -> length args
        _ -> 0
  modifyIORef' natives (Map.insert n.name arity)
  pure $ MLIR.MkExprNative n ty
convert (MLIR.MkExprIndex e i) = MLIR.MkExprIndex <$> convert e <*> convert i
convert (MLIR.MkExprUnpack x e e') = MLIR.MkExprUnpack x <$> convert e <*> convert e'

convertUpdate :: MonadIO m => MLIR.Update -> m MLIR.Update
convertUpdate (MLIR.MkUpdtVariable x) = pure $ MLIR.MkUpdtVariable x
convertUpdate (MLIR.MkUpdtField u f) = MLIR.MkUpdtField <$> convertUpdate u <*> pure f
convertUpdate (MLIR.MkUpdtIndex u e) = MLIR.MkUpdtIndex <$> convertUpdate u <*> convert e

runClosureConversion :: MonadIO m => [MLIR.Expression] -> m [MLIR.Expression]
runClosureConversion = mapM convert