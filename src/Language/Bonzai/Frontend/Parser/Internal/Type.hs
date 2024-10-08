module Language.Bonzai.Frontend.Parser.Internal.Type where
import qualified Language.Bonzai.Frontend.Parser as P
import qualified Language.Bonzai.Syntax.HLIR as HLIR
import qualified Language.Bonzai.Frontend.Parser.Lexer as Lex

parseType :: (MonadIO m) => P.Parser m HLIR.Type
parseType = 
  P.choice [
    do
      void $ Lex.reserved "fn"
      tys <- Lex.parens $ P.sepBy parseType Lex.comma
      ret <- Lex.symbol ":" *> parseType

      pure $ tys HLIR.:->: ret,
    P.try $ do
      idt <- Lex.identifier
      tys <- Lex.angles $ P.sepBy1 parseType Lex.comma

      pure $ HLIR.MkTyApp (HLIR.MkTyId idt) tys,
    Lex.identifier <&> HLIR.MkTyId
  ]
