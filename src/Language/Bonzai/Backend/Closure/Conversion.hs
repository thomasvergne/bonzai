{-# LANGUAGE LambdaCase #-}
module Language.Bonzai.Backend.Closure.Conversion where
import qualified Language.Bonzai.Syntax.MLIR as MLIR
import qualified Data.Set as Set
import qualified GHC.IO as IO
import qualified Language.Bonzai.Backend.Closure.Free as M
import qualified Data.Map as Map
import Control.Monad.Result (compilerError)

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
convert (MLIR.MkExprVariable x) = pure $ MLIR.MkExprVariable x
convert (MLIR.MkExprLiteral x) = pure $ MLIR.MkExprLiteral x
convert (MLIR.MkExprLet x e) | isLambda e = case getLambda e of
  MLIR.MkExprLambda args body -> do
    b <- convertLambda (Set.singleton x) (MLIR.MkExprLambda args body)
    pure $ MLIR.MkExprLet x b
  _ -> compilerError "expected lambda"
convert (MLIR.MkExprLambda args body) = convertLambda Set.empty (MLIR.MkExprLambda args body)
convert (MLIR.MkExprApplication f args) = do
  globals' <- readIORef globals
  natives' <- readIORef natives

  let reserved = globals' <> natives'

  args' <- mapM (\case
    e | isVariable e, name <- getVariable e -> case Map.lookup name reserved of
      Just arity | arity >= 0 -> do
        let args' = take arity $ map (\n -> "arg" <> show n) [(0 :: Integer)..]
        convert $ MLIR.MkExprLambda args' (MLIR.MkExprApplication (MLIR.MkExprVariable name) (map MLIR.MkExprVariable args'))
      _ -> pure e
    e -> convert e) args

  case f of
    e | isVariable e, name <- getVariable e, Map.member name reserved -> do
      pure $ MLIR.MkExprApplication e args'
    _ -> do
      name <- freshLambda "call"
      f' <- convert f

      let callVar = MLIR.MkExprVariable name
      let function = MLIR.MkExprIndex callVar (MLIR.MkExprLiteral (MLIR.MkLitInt 0))
      let env = MLIR.MkExprIndex callVar (MLIR.MkExprLiteral (MLIR.MkLitInt 1))

      let call = MLIR.MkExprApplication function (env : args')

      pure $ MLIR.MkExprUnpack name f' call
convert (MLIR.MkExprLet n e) | isVariable e = do
  pure $ MLIR.MkExprLet n e
convert (MLIR.MkExprLet x e) = MLIR.MkExprLet x <$> convert e
convert (MLIR.MkExprMut e) = MLIR.MkExprMut <$> convert e
convert (MLIR.MkExprList xs) = MLIR.MkExprList <$> mapM convert xs
convert (MLIR.MkExprTernary c t e) = MLIR.MkExprTernary <$> convert c <*> convert t <*> convert e
convert (MLIR.MkExprUpdate u e) = MLIR.MkExprUpdate <$> convertUpdate u <*> convert e
convert (MLIR.MkExprBlock es) = MLIR.MkExprBlock <$> mapM convert es
convert (MLIR.MkExprEvent es) = do
  let freeVars = M.free es
  nativesFuns <- readIORef natives
  globals' <- readIORef globals
  let finalNativesFuns = Map.keysSet (nativesFuns <> globals')

  let env = freeVars Set.\\ finalNativesFuns

  let envAsList = Set.toList env
      dict = MLIR.MkExprList $ map MLIR.MkExprVariable envAsList

  let prefixBody = zipWith (\n i -> do
            MLIR.MkExprLet n (MLIR.MkExprIndex (MLIR.MkExprVariable "env") (MLIR.MkExprLiteral (MLIR.MkLitInt i)))
          ) envAsList [0..]

  es' <- mapM convert es

  pure $ MLIR.MkExprList [
      MLIR.MkExprEvent (map (`incorporate` prefixBody) es'),
      dict
    ]

  where
    incorporate :: MLIR.MLIR "expression" -> [MLIR.MLIR "expression"] -> MLIR.MLIR "expression"
    incorporate e [] = e
    incorporate (MLIR.MkExprLoc p e) xs = MLIR.MkExprLoc p (incorporate e xs)
    incorporate (MLIR.MkExprOn ev args e) xs = MLIR.MkExprOn ev args (addLets e xs)
    incorporate e _ = e

    addLets :: MLIR.MLIR "expression" -> [MLIR.MLIR "expression"] -> MLIR.MLIR "expression"
    addLets e [] = e
    addLets (MLIR.MkExprLoc p e) xs = MLIR.MkExprLoc p (addLets e xs)
    addLets (MLIR.MkExprBlock es') xs = MLIR.MkExprBlock (xs <> es')
    addLets e xs = MLIR.MkExprBlock (xs <> [e])
convert (MLIR.MkExprOn ev args body) = do
  body' <- convert body

  pure (MLIR.MkExprOn ev ("env" : args) body')
convert (MLIR.MkExprSend e ev es) = do
  args' <- mapM convert es

  name <- freshLambda "call"
  e' <- convert e

  let callVar = MLIR.MkExprVariable name
  let function = MLIR.MkExprIndex callVar (MLIR.MkExprLiteral (MLIR.MkLitInt 0))
  let env = MLIR.MkExprIndex callVar (MLIR.MkExprLiteral (MLIR.MkLitInt 1))

  pure $ MLIR.MkExprUnpack name e' (MLIR.MkExprSend function ev (env : args'))
convert (MLIR.MkExprSpawn e) = do
  e' <- convert e
  name <- freshLambda "spawn"
  let callVar = MLIR.MkExprVariable name

  let ev = MLIR.MkExprIndex callVar (MLIR.MkExprLiteral (MLIR.MkLitInt 0))
  let env = MLIR.MkExprIndex callVar (MLIR.MkExprLiteral (MLIR.MkLitInt 1))

  pure $ MLIR.MkExprUnpack name e' (MLIR.MkExprList [MLIR.MkExprSpawn ev, env])
convert (MLIR.MkExprNative n ty) = do
  let arity = case ty of
        args MLIR.:->: _ -> length args
        _ -> (-1)
  modifyIORef' natives (Map.insert n.name arity)
  pure $ MLIR.MkExprNative n ty
convert (MLIR.MkExprIndex e i) = MLIR.MkExprIndex <$> convert e <*> convert i
convert (MLIR.MkExprUnpack x e e') = MLIR.MkExprUnpack x <$> convert e <*> convert e'
convert (MLIR.MkExprLoc p e) = MLIR.MkExprLoc p <$> convert e
convert (MLIR.MkExprWhile c e) = MLIR.MkExprWhile <$> convert c <*> convert e
convert MLIR.MkExprSpecial = pure MLIR.MkExprSpecial
convert (MLIR.MkExprTryCatch e n e') = MLIR.MkExprTryCatch <$> convert e <*> pure n <*> convert e'

convertLambda :: MonadIO m => Set Text -> MLIR.Expression -> m MLIR.Expression
convertLambda reserved (MLIR.MkExprLambda args body) = do
  let freeVars = M.free body
  nativesFuns <- readIORef natives
  globals' <- readIORef globals
  let finalNativesFuns = Map.keysSet (nativesFuns <> globals') Set.\\ Set.fromList args

  let env = freeVars Set.\\ (finalNativesFuns <> Set.fromList args <> reserved)
      envAsList = Set.toList env
      dict = MLIR.MkExprList $ map MLIR.MkExprVariable envAsList

  let prefixBody = zipWith (\n i -> do
          MLIR.MkExprLet n (MLIR.MkExprIndex (MLIR.MkExprVariable "env") (MLIR.MkExprLiteral (MLIR.MkLitInt i)))
        ) envAsList [0..]

  body' <- convert body

  let finalBody = case removeLoc body' of
          MLIR.MkExprBlock es -> MLIR.MkExprBlock $ prefixBody <> es
          e -> MLIR.MkExprBlock $ prefixBody <> [e]

  pure (MLIR.MkExprList [
      MLIR.MkExprLambda ("env" : args) finalBody,
      dict
    ])
convertLambda _ e = convert e

convertUpdate :: MonadIO m => MLIR.Update -> m MLIR.Update
convertUpdate (MLIR.MkUpdtVariable x) = pure $ MLIR.MkUpdtVariable x
convertUpdate (MLIR.MkUpdtField u f) = MLIR.MkUpdtField <$> convertUpdate u <*> pure f
convertUpdate (MLIR.MkUpdtIndex u e) = MLIR.MkUpdtIndex <$> convertUpdate u <*> convert e

convertToplevel :: MonadIO m => MLIR.Expression -> m MLIR.Expression
convertToplevel (MLIR.MkExprLet x e) = do
  modifyIORef' globals (Map.insert x (getArity e))

  MLIR.MkExprLet x <$> if isLambda e
    then case getLambda e of
      MLIR.MkExprLambda args body -> do
        body' <- convert body
        pure $ MLIR.MkExprLambda args body'
      _ -> compilerError "expected lambda"
    else convert e
convertToplevel (MLIR.MkExprUpdate u e) | isLambda e = do
  case getLambda e of
    MLIR.MkExprLambda args body -> do
      body' <- convert body
      pure $ MLIR.MkExprUpdate u (MLIR.MkExprLambda args body')
    _ -> compilerError "expected lambda"
convertToplevel (MLIR.MkExprLoc p e) = MLIR.MkExprLoc p <$> convertToplevel e
convertToplevel e = convert e

analyzeProgram :: MonadIO m => MLIR.Expression -> m ()
analyzeProgram (MLIR.MkExprLet x e) = do
  let arity = getArity e

  when (arity >= 0) $ do
    modifyIORef' globals (Map.insert x arity)
analyzeProgram (MLIR.MkExprLoc _ e) = analyzeProgram e
analyzeProgram (MLIR.MkExprNative ann ty) = do
  let arity = case ty of
        args MLIR.:->: _ -> length args
        _ -> (-1)
  modifyIORef' natives (Map.insert ann.name arity)
analyzeProgram _ = pure ()

removeLoc :: MLIR.Expression -> MLIR.Expression
removeLoc (MLIR.MkExprLoc _ e) = removeLoc e
removeLoc e = e

getArity :: MLIR.Expression -> Int
getArity (MLIR.MkExprLambda args _) = length args
getArity (MLIR.MkExprLoc _ e) = getArity e
getArity _ = -1

isVariable :: MLIR.Expression -> Bool
isVariable (MLIR.MkExprVariable _) = True
isVariable (MLIR.MkExprLoc _ e) = isVariable e
isVariable _ = False

getVariable :: MLIR.Expression -> Text
getVariable (MLIR.MkExprVariable x) = x
getVariable (MLIR.MkExprLoc _ e) = getVariable e
getVariable _ = compilerError "expected variable"

isLambda :: MLIR.MLIR "expression" -> Bool
isLambda (MLIR.MkExprLambda _ _) = True
isLambda (MLIR.MkExprLoc _ e) = isLambda e
isLambda _ = False

getLambda :: MLIR.MLIR "expression" -> MLIR.MLIR "expression"
getLambda b@(MLIR.MkExprLambda {}) = b
getLambda (MLIR.MkExprLoc _ e) = getLambda e
getLambda e = e

runClosureConversion :: MonadIO m => [MLIR.Expression] -> m [MLIR.Expression]
runClosureConversion xs = mapM_ analyzeProgram xs >> mapM convertToplevel xs
