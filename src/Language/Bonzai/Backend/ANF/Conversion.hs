module Language.Bonzai.Backend.ANF.Conversion where

import qualified Language.Bonzai.Syntax.MLIR as MLIR
import qualified GHC.IO as IO

{-# NOINLINE symbolCounter #-}
symbolCounter :: IORef Int
symbolCounter = IO.unsafePerformIO $ newIORef 0

freshSymbol :: MonadIO m => Text -> m Text
freshSymbol prefix = do
  i <- readIORef symbolCounter
  modifyIORef' symbolCounter (+1)
  
  pure $ prefix <> show i

convert 
  :: MonadIO m 
  => MLIR.MLIR "expression" 
  -> m (MLIR.MLIR "expression", [(Text, MLIR.MLIR "expression")])
convert (MLIR.MkExprVariable a) = pure (MLIR.MkExprVariable a, [])
convert (MLIR.MkExprApplication f args) = do
  (f', stmts1) <- convert f
  (args', stmts2) <- mapAndUnzipM convert args
  
  pure (MLIR.MkExprApplication f' args', stmts1 <> concat stmts2)
convert (MLIR.MkExprLambda args body) = do
  (body', stmts) <- convert body
  
  pure (MLIR.MkExprLambda args body', stmts)
convert (MLIR.MkExprTernary c t e) = do
  (c', stmts1) <- convert c
  (t', stmts2) <- convert t
  (e', stmts3) <- convert e
  
  pure (MLIR.MkExprTernary c' t' e', stmts1 <> stmts2 <> stmts3)
convert (MLIR.MkExprUpdate u e) = do
  (u', stmts1) <- convertUpdate u
  (e', stmts2) <- convert e
  
  pure (MLIR.MkExprUpdate u' e', stmts1 <> stmts2)
convert (MLIR.MkExprLet a e) = do
  (e', stmts) <- convert e
  
  pure (MLIR.MkExprLet a e', stmts)
convert (MLIR.MkExprMut a e) = do
  (e', stmts) <- convert e
  
  pure (MLIR.MkExprMut a e', stmts)
convert (MLIR.MkExprBlock es) = do
  es' <- mapM convert es
  let exprs = createBlock es'
  
  pure (MLIR.MkExprBlock exprs, [])
convert (MLIR.MkExprEvent es) = do
  (es', stmts) <- mapAndUnzipM convert es
  
  pure (MLIR.MkExprEvent es', concat stmts)
convert (MLIR.MkExprOn ev args e) = do
  (e', stmts) <- convert e
  
  pure (MLIR.MkExprOn ev args e', stmts)
convert (MLIR.MkExprSend e ev es) = do
  (e', stmts1) <- convert e
  (es', stmts2) <- mapAndUnzipM convert es
  
  pure (MLIR.MkExprSend e' ev es', stmts1 <> concat stmts2)
convert (MLIR.MkExprSpawn e) = do
  (e', stmts) <- convert e
  
  pure (MLIR.MkExprSpawn e', stmts)
convert (MLIR.MkExprList es) = do
  (es', stmts) <- mapAndUnzipM convert es
  
  pure (MLIR.MkExprList es', concat stmts)
convert (MLIR.MkExprNative n ty) = pure (MLIR.MkExprNative n ty, [])
convert (MLIR.MkExprIndex e i) = do
  (e', stmts1) <- convert e
  (i', stmts2) <- convert i
  
  pure (MLIR.MkExprIndex e' i', stmts1 <> stmts2)
convert (MLIR.MkExprLiteral l) = pure (MLIR.MkExprLiteral l, [])
convert (MLIR.MkExprUnpack n e e') = do
  (e'', stmts1) <- convert e
  (e''', stmts2) <- convert e'

  name <- freshSymbol "anf"
  
  pure (MLIR.MkExprVariable n, stmts1 <> stmts2 <> [(n, e'')] <> [(name, e''')])

convertUpdate :: MonadIO m => MLIR.MLIR "update" -> m (MLIR.MLIR "update", [(Text, MLIR.MLIR "expression")])
convertUpdate (MLIR.MkUpdtVariable a) = pure (MLIR.MkUpdtVariable a, [])
convertUpdate (MLIR.MkUpdtField u f) = do
  (u', stmts) <- convertUpdate u
  
  pure (MLIR.MkUpdtField u' f, stmts)
convertUpdate (MLIR.MkUpdtIndex u e) = do
  (u', stmts1) <- convertUpdate u
  (e', stmts2) <- convert e
  
  pure (MLIR.MkUpdtIndex u' e', stmts1 <> stmts2)

createBlock :: [(MLIR.Expression, [(Text, MLIR.Expression)])] -> [MLIR.Expression]
createBlock ((e, stmts) : xs) = map createLet stmts <> [e] <> createBlock xs
createBlock [] = []

createLet :: (Text, MLIR.Expression) -> MLIR.Expression
createLet (n, e) = MLIR.MkExprLet n e

runANFConversion :: MonadIO m => [MLIR.MLIR "expression"] -> m [MLIR.MLIR "expression"]
runANFConversion xs = createBlock <$> mapM convert xs