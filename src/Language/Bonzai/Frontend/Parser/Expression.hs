module Language.Bonzai.Frontend.Parser.Expression where

import qualified Language.Bonzai.Frontend.Parser as P
import qualified Language.Bonzai.Frontend.Parser.Lexer as Lex
import qualified Language.Bonzai.Frontend.Parser.Internal.Literal as Lit
import qualified Language.Bonzai.Syntax.HLIR as HLIR
import qualified Language.Bonzai.Frontend.Parser.Internal.Type as Typ
import qualified Control.Monad.Combinators.Expr as P
import qualified Text.Megaparsec.Char as P
import qualified Data.Text as Text

parseAnnotation :: MonadIO m => P.Parser m a -> P.Parser m (HLIR.Annotation (Maybe a))
parseAnnotation p = P.choice [
    P.try $ do
      name <- Lex.identifier
      ty <- P.optional (Lex.symbol ":" *> p)

      pure $ HLIR.MkAnnotation name ty,
    HLIR.MkAnnotation <$> Lex.identifier <*> pure Nothing
  ]

parseAnnotation' :: MonadIO m => P.Parser m a -> P.Parser m (HLIR.Annotation a)
parseAnnotation' p = HLIR.MkAnnotation <$> Lex.identifier <*> (Lex.symbol ":" *> p)

localize :: (MonadIO m, HLIR.Locate a) => P.Parser m a -> P.Parser m a
localize p = do
  start <- P.getSourcePos
  x <- p
  end <- P.getSourcePos

  pure $ HLIR.locate x (start, end)

parseLiteral :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseLiteral = localize . Lex.lexeme $ P.choice [
    HLIR.MkExprLiteral <$> Lit.parseLiteral,
    parseInterpolatedString
  ]

parseInterpolatedString :: (MonadIO m) => P.Parser m (HLIR.HLIR "expression")
parseInterpolatedString = do
  parts <- buildString . toString <$> Lit.parseString

  pure $ buildExprString parts
  where
    buildString :: [Char] -> HLIR.HLIR "expression"
    buildString [] = HLIR.MkExprLiteral (HLIR.MkLitString "")
    buildString ('\\':'$':xs) = HLIR.MkExprBinary "+" Nothing (HLIR.MkExprString "$") (buildString xs)
    buildString ('$':x:xs) | Lex.isIdentCharStart (Text.singleton x) = do
      -- span the variable name
      let (var, rest) = span Lex.isIdentChar xs
      let var' = HLIR.MkExprVariable (HLIR.MkAnnotation (Text.pack (x:var)) Nothing)

      HLIR.MkExprBinary "+" Nothing var' (buildString rest)
    buildString (x:xs) = HLIR.MkExprBinary "+" Nothing (HLIR.MkExprString (Text.singleton x)) (buildString xs)

    buildExprString :: HLIR.HLIR "expression" -> HLIR.HLIR "expression"
    buildExprString (HLIR.MkExprBinary "+" Nothing (HLIR.MkExprString "") x) =
      buildExprString x
    buildExprString (HLIR.MkExprBinary "+" Nothing x (HLIR.MkExprString "")) =
      buildExprString x
    buildExprString (HLIR.MkExprBinary "+" Nothing (HLIR.MkExprString a) (HLIR.MkExprString b)) =
      HLIR.MkExprString (a <> b)
    buildExprString (HLIR.MkExprBinary "+" Nothing (HLIR.MkExprString a) x) =
      buildExprString $ HLIR.MkExprBinary "+" Nothing (HLIR.MkExprString a) (buildExprString x)
    buildExprString (HLIR.MkExprBinary "+" Nothing x (HLIR.MkExprString a)) =
      buildExprString $ HLIR.MkExprBinary "+" Nothing (buildExprString x) (HLIR.MkExprString a)
    buildExprString x = x

parseTernary :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseTernary = localize $ do
  void $ Lex.reserved "if"
  cond <- parseExpression

  void $ Lex.reserved "then"
  then' <- parseExpression

  void $ Lex.reserved "else"

  HLIR.MkExprTernary cond then' <$> parseExpression

parseList :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseList = localize $ do
  void $ Lex.symbol "["
  exprs <- P.sepBy parseExpression Lex.comma
  void $ Lex.symbol "]"

  pure $ HLIR.MkExprList exprs

parseExtern :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseExtern = localize $ do
  void $ Lex.reserved "extern"
  void $ Lex.reserved "fn"
  name <- Lex.identifier <|> Lex.parens Lex.operator
  gens <- P.option [] $ Lex.angles (P.sepBy Lex.identifier Lex.comma)

  args <- Lex.parens $ P.sepBy (parseAnnotation' Typ.parseType) Lex.comma
  ret <- P.option HLIR.MkTyUnit $ Lex.symbol ":" *> Typ.parseType

  let funTy = map (.value) args HLIR.:->: ret

  pure $ HLIR.MkExprNative (HLIR.MkAnnotation name gens) funTy

parseVariable :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseVariable = localize $ do
  name <- Lex.lexeme Lex.identifier

  pure $ HLIR.MkExprVariable $ HLIR.MkAnnotation name Nothing

parseLet :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseLet = localize $ do
  void $ Lex.reserved "let"
  name <- Lex.identifier <|> Lex.parens Lex.operator
  void $ Lex.reserved "="

  HLIR.MkExprLet mempty (HLIR.MkAnnotation name Nothing) <$> parseExpression

parseLive :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseLive = localize $ do
  void $ Lex.reserved "live"
  name <- Lex.identifier <|> Lex.parens Lex.operator
  void $ Lex.reserved "="

  HLIR.MkExprLive (HLIR.MkAnnotation name Nothing) <$> parseExpression

parseMut :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseMut = localize $ do
  void $ Lex.reserved "mut"
  name <- Lex.identifier <|> Lex.parens Lex.operator
  void $ Lex.reserved "="

  HLIR.MkExprMut (HLIR.MkAnnotation name Nothing) <$> parseExpression

parseDatatype :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseDatatype = localize $ do
  void $ Lex.reserved "type"
  name <- Lex.identifier
  gens <- P.option [] $ Lex.angles (P.sepBy Lex.identifier Lex.comma)

  HLIR.MkExprData (HLIR.MkAnnotation name gens) <$> Lex.braces (P.sepBy1 parseDataConstructor Lex.comma)

  where
    parseDataConstructor :: MonadIO m => P.Parser m (HLIR.DataConstructor HLIR.Type)
    parseDataConstructor = P.choice [
       P.try $ HLIR.MkDataConstructor
            <$> Lex.identifier
            <*> Lex.parens (P.sepBy ((.value) <$> parseAnnotation' Typ.parseType) Lex.comma),
        HLIR.MkDataVariable <$> Lex.identifier
      ]

parseInterface :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseInterface = localize $ do
  void $ Lex.reserved "interface"
  name <- Lex.identifier
  gens <- P.option [] $ Lex.angles (P.sepBy Lex.identifier Lex.comma)

  HLIR.MkExprInterface (HLIR.MkAnnotation name gens) <$> Lex.braces (P.many parseDef)

  where
    parseDef :: MonadIO m => P.Parser m (HLIR.Annotation HLIR.Type)
    parseDef = do
      void $ Lex.reserved "fn"
      name <- Lex.identifier <|> Lex.parens Lex.operator

      args <- P.option [] $ Lex.parens (P.sepBy (parseAnnotation' Typ.parseType) Lex.comma)

      let funTy = map (.value) args HLIR.:->: HLIR.MkTyUnit

      pure $ HLIR.MkAnnotation name funTy

parseMatch :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseMatch = localize $ do
  void $ Lex.reserved "match"
  expr <- parseExpression

  void $ Lex.symbol "{"
  cases <- P.some parseCase
  void $ Lex.symbol "}"

  pure $ HLIR.MkExprMatch expr cases

  where
    parseCase :: MonadIO m => P.Parser m (HLIR.HLIR "pattern", HLIR.HLIR "expression")
    parseCase = do
      void $ Lex.reserved "case"
      pat <- parsePattern

      void $ Lex.symbol "=>"
      expr <- parseExpression

      pure (pat, expr)

    parsePatternTerm :: MonadIO m => P.Parser m (HLIR.HLIR "pattern")
    parsePatternTerm = P.choice [
        Lex.brackets $ do
          pats <- P.sepBy parsePattern Lex.comma
          slice <- P.optional (Lex.symbol ".." *> parsePattern)

          pure (HLIR.MkPatList pats slice),
        P.try $ HLIR.MkPatConstructor <$> Lex.identifier <*> Lex.parens (P.sepBy1 parsePattern Lex.comma),
        HLIR.MkPatLiteral <$> Lex.lexeme (P.choice [Lit.parseLiteral, HLIR.MkLitString <$> Lit.parseString]),
        HLIR.MkPatWildcard <$ Lex.symbol "_",
        HLIR.MkPatVariable <$> Lex.identifier <*> pure Nothing
      ]

    parsePattern :: MonadIO m => P.Parser m (HLIR.HLIR "pattern")
    parsePattern = P.makeExprParser parsePatternTerm table
      where
        table = [
            [
              P.InfixL $ do
                void $ Lex.symbol "|"
                pure $ \a b -> HLIR.MkPatOr a b
            ]
          ]



parseWhile :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseWhile = localize $ do
  void $ Lex.reserved "while"
  cond <- parseExpression

  void $ Lex.symbol "{"
  body <- P.many parseExpression
  void $ Lex.symbol "}"

  pure $ HLIR.MkExprWhile cond (HLIR.MkExprBlock body)

parseBlock :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseBlock = localize $ do
  void $ Lex.symbol "{"
  exprs <- P.many parseExpression
  void $ Lex.symbol "}"

  pure $ HLIR.MkExprBlock exprs

parseFunction :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseFunction = localize $ do
  void $ Lex.reserved "fn"
  name <- Lex.identifier <|> Lex.parens Lex.operator
  generics <- P.option [] $ Lex.angles (P.sepBy Lex.identifier Lex.comma)
  args <- Lex.parens (P.sepBy (parseAnnotation Typ.parseType) Lex.comma)
  ret <- P.option Nothing $ Just <$> (Lex.symbol ":" *> Typ.parseType)

  void $ Lex.symbol "=>"

  let funTy = (HLIR.:->:) <$> mapM HLIR.value args <*> ret

  HLIR.MkExprLet (fromList generics) (HLIR.MkAnnotation name funTy) . HLIR.MkExprLambda args ret <$> parseExpression

parseLambda :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseLambda = localize $ do
  void $ Lex.reserved "fn"
  args <- Lex.parens (P.sepBy (parseAnnotation Typ.parseType) Lex.comma)
  ret <- P.option Nothing $ Just <$> (Lex.symbol ":" *> Typ.parseType)

  void $ Lex.symbol "=>"

  HLIR.MkExprLambda args ret <$> parseExpression

parseUpdate :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseUpdate = localize $ do
  name <- P.try $ (Lex.identifier <|> Lex.parens Lex.operator) <* Lex.symbol "="

  HLIR.MkExprUpdate (HLIR.MkUpdtVariable (HLIR.MkAnnotation name Nothing)) <$> parseExpression

parseActor :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseActor = localize $ do
  void $ Lex.reserved "actor"
  name <- Lex.identifier <|> Lex.parens Lex.operator
  implemented <- Lex.symbol "<" *> Typ.parseType
  HLIR.MkExprLet mempty (HLIR.MkAnnotation name Nothing)
    . HLIR.MkExprActor implemented
      <$> Lex.braces (P.many parseEvent)

parseAnonActor :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseAnonActor = localize $ do
  void $ Lex.reserved "actor"
  implemented <- Lex.symbol "<" *> Typ.parseType
  HLIR.MkExprActor implemented <$> Lex.braces (P.many parseEvent)

parseEvent :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseEvent = localize $ do
  void $ Lex.reserved "on"
  name <- Lex.identifier <|> Lex.parens Lex.operator
  args <- Lex.parens (P.sepBy (parseAnnotation Typ.parseType) Lex.comma)

  void $ Lex.symbol "=>"

  HLIR.MkExprOn name args <$> parseExpression

parseSpawn :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseSpawn = localize $ do
  void $ Lex.reserved "spawn"
  HLIR.MkExprSpawn <$> parseExpression

parseRequire :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseRequire = localize $ do
  void $ Lex.reserved "require"

  HLIR.MkExprRequire <$> Lex.lexeme Lit.parseString

parseTerm :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseTerm =
  localize $ P.choice [
    parseWhile,
    P.try parseActor,
    parseAnonActor,
    parseSpawn,
    P.try parseFunction,
    parseLambda,
    parseLet,
    parseLive,
    parseMut,
    parseMatch,
    parseTernary,
    parseLiteral,
    parseBlock,
    parseList,
    P.try parseUpdate,
    parseVariable,
    Lex.parens parseExpression
  ]

parseExpression :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseExpression = localize $ P.makeExprParser parseTerm table
  where
    table = [
        [
          P.Postfix . Lex.makeUnaryOp $ do
            args <- Lex.parens (P.sepBy parseExpression Lex.comma)
            pure $ \e -> HLIR.MkExprApplication e args
        ],
        [
            P.Postfix . Lex.makeUnaryOp $ do
              field <- P.char '.' *> Lex.nonLexedID <* Lex.scn
              args <- P.option [] $ Lex.parens (P.sepBy parseExpression Lex.comma)
              let var = HLIR.MkExprVariable (HLIR.MkAnnotation field Nothing)
              pure $ \e -> HLIR.MkExprApplication var (e:args)
        ],
        [
          P.Postfix . Lex.makeUnaryOp $ do
            void $ Lex.symbol "["
            idx <- parseExpression
            void $ Lex.symbol "]"

            pure $ \e -> HLIR.MkExprIndex e idx
        ],
        [
          P.Postfix . Lex.makeUnaryOp $ do
            void $ Lex.symbol "->"
            name <- Lex.identifier
            args <- Lex.parens (P.sepBy parseExpression Lex.comma)

            pure $ \e -> HLIR.MkExprSend e name args
        ],
        [
          P.InfixL $ do
            void $ Lex.symbol "*"
            pure $ \a b -> HLIR.MkExprBinary "*" Nothing a b,
          P.InfixL $ do
            void $ Lex.symbol "/"
            pure $ \a b -> HLIR.MkExprBinary "/" Nothing a b
        ],
        [
          P.InfixL $ do
            void $ Lex.symbol "+"
            pure $ \a b -> HLIR.MkExprBinary "+" Nothing a b,
          P.InfixL $ do
            void $ Lex.symbol "-"
            pure $ \a b -> HLIR.MkExprBinary "-" Nothing a b
        ],
        [
          P.InfixN $ do
            void $ Lex.symbol "=="
            pure $ \a b -> HLIR.MkExprBinary "==" Nothing a b,
          P.InfixN $ do
            void $ Lex.symbol "!="
            pure $ \a b -> HLIR.MkExprBinary "!=" Nothing a b
        ],
        [
          P.InfixN $ do
            void $ Lex.symbol ">="
            pure $ \a b -> HLIR.MkExprBinary ">=" Nothing a b,
          P.InfixN $ do
            void $ Lex.symbol "<="
            pure $ \a b -> HLIR.MkExprBinary "<=" Nothing a b,
          P.InfixN $ do
            void $ Lex.symbol ">"
            pure $ \a b -> HLIR.MkExprBinary ">" Nothing a b,
          P.InfixN $ do
            void $ Lex.symbol "<"
            pure $ \a b -> HLIR.MkExprBinary "<" Nothing a b
        ],
        [
          P.InfixL $ do
            void $ Lex.symbol "&&"
            pure $ \a b -> HLIR.MkExprBinary "&&" Nothing a b,
          P.InfixL $ do
            void $ Lex.symbol "||"
            pure $ \a b -> HLIR.MkExprBinary "||" Nothing a b
        ],
        [
          P.Prefix . Lex.makeUnaryOp $ do
            void $ Lex.symbol "!"
            pure $ \a -> HLIR.MkExprApplication (HLIR.MkExprVariable (HLIR.MkAnnotation "!" Nothing)) [a]
        ],
        [
          P.InfixL $ do
            op <- Lex.operator
            pure $ \a b -> HLIR.MkExprBinary op Nothing a b
        ],
        [
          P.InfixL $ do
            Lex.scn
            void $ P.char ':'
            name <- Lex.nonLexedID
            void $ P.char ':'
            Lex.scn

            pure $ \a b -> HLIR.MkExprBinary name Nothing a b
        ]
      ]

parseToplevel :: MonadIO m => P.Parser m (HLIR.HLIR "expression")
parseToplevel =
  localize $ P.choice [
    parseInterface,
    parseDatatype,
    parseRequire,
    parseExtern,
    parseExpression
  ]

parseProgram :: MonadIO m => P.Parser m [HLIR.HLIR "expression"]
parseProgram = Lex.scn *> P.many parseToplevel <* P.eof
