{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}

module Main where

import Language.LSP.Protocol.Message
import Language.LSP.Protocol.Types
import Language.LSP.Server
import Data.Maybe (fromJust)
import System.Exit (ExitCode(ExitFailure))
import qualified Language.Bonzai.Frontend.Parser.Lexer as Lex
import qualified Language.Bonzai.Syntax.HLIR as HLIR
import Language.Bonzai.Frontend.Typechecking.Checker (runTypechecking, decomposeHeader)
import Data.Map qualified as Map
import System.FilePath (takeDirectory, dropExtension, takeFileName)
import Language.Bonzai.Frontend.Module.Conversion (moduleState, ModuleState (MkModuleState), resolve, removeRequires, resultState, resolveContent)
import Language.Bonzai.Frontend.Parser hiding (parse)
import qualified Data.Text as Text
import Relude.Unsafe ((!!))
import GHC.IO (unsafePerformIO)

{-# NOINLINE lastValidAST #-}
lastValidAST :: IORef [HLIR.TLIR "expression"]
lastValidAST = unsafePerformIO $ newIORef []

getVar :: HLIR.TLIR "expression" -> (Position, Uri) -> Maybe (Text, HLIR.Type)
getVar (HLIR.MkExprLet _ ann e) p = case getVar e p of
  Just (name, ty) -> Just (name, ty)
  Nothing -> Just (HLIR.name ann, runIdentity $ HLIR.value ann)
getVar (HLIR.MkExprNative ann ty) _ = Just (HLIR.name ann, ty)
getVar (HLIR.MkExprVariable ann) _ = Just (HLIR.name ann, runIdentity $ HLIR.value ann)
getVar (HLIR.MkExprLoc e (start, end)) ref = do
  let (Position line col, uri) = ref
  let pos' = SourcePos 
              (fromMaybe "" (uriToFilePath uri))
              (mkPos $ fromIntegral line + 1) 
              (mkPos $ fromIntegral col + 1)

  let cond = pos' >= start && pos' < end

  if cond
    then getVar e ref
    else Nothing
getVar (HLIR.MkExprLambda _ _ body) pos = getVar body pos
getVar (HLIR.MkExprMatch e cs) pos = do
  let (Position line col, uri) = pos
  let pos' = SourcePos 
              (fromMaybe "" (uriToFilePath uri))
              (mkPos $ fromIntegral line + 1) 
              (mkPos $ fromIntegral col + 1)

  let vars = map (\(p, e', (start, end)) -> do
        if pos' >= start && pos' < end 
          then case getVar e' pos of
            Just x -> Just x
            Nothing -> getVarInPattern p pos
          else Nothing
        ) cs
  case getVar e pos of
    Just x -> Just x
    Nothing -> case catMaybes vars of
      (x:_) -> Just x
      [] -> Nothing
getVar (HLIR.MkExprTernary c t e) pos = getVar c pos <|> getVar t pos <|> getVar e pos
getVar (HLIR.MkExprBlock es) pos = foldr (\e acc -> getVar e pos <|> acc) Nothing es
getVar (HLIR.MkExprApplication f args) pos =
  case foldr (\e acc -> getVar e pos <|> acc) Nothing args of
    Just x -> Just x
    Nothing -> getVar f pos
getVar (HLIR.MkExprActor ty events) pos =
  case foldr (\e acc -> getVar e pos <|> acc) Nothing events of
    Just x -> Just x
    Nothing -> Just (toText ty, ty)
getVar (HLIR.MkExprList l) pos = foldr (\e acc -> getVar e pos <|> acc) Nothing l
getVar (HLIR.MkExprOn name args body) pos = case  getVar body pos of
  Just x -> Just x
  Nothing -> do
    let argsTys = map (runIdentity . HLIR.value) args

    Just (name, argsTys HLIR.:->: HLIR.MkTyUnit)
getVar (HLIR.MkExprWhile c b) pos = getVar b pos <|> getVar c pos
getVar (HLIR.MkExprSend e ev args ty) pos =
  case foldr (\e' acc -> getVar e' pos <|> acc) Nothing args of
    Just x -> Just x
    Nothing -> case getVar e pos of
      Just x -> Just x
      Nothing -> Just (ev, runIdentity ty)
getVar (HLIR.MkExprUpdate up val) pos = do
  case getVar val pos of
    Just x -> Just x
    Nothing -> case up of
      HLIR.MkUpdtVariable name -> Just (HLIR.name name, runIdentity $ HLIR.value name)
      _ -> Nothing
getVar _ _ = Nothing

getVarInPattern :: HLIR.TLIR "pattern" -> (Position, Uri) -> Maybe (Text, HLIR.Type)
getVarInPattern (HLIR.MkPatVariable name ty) _ = Just (name, runIdentity ty)
getVarInPattern (HLIR.MkPatLocated p (start, end)) ref = do
  let (Position line col, uri) = ref
  let pos' = SourcePos
              (fromMaybe "" (uriToFilePath uri))
              (mkPos $ fromIntegral line + 1)
              (mkPos $ fromIntegral col + 1)

  let cond = pos' >= start && pos' < end

  if cond
    then getVarInPattern p ref
    else Nothing
getVarInPattern (HLIR.MkPatList l sl) pos = do
  case foldr (\p acc -> getVarInPattern p pos <|> acc) Nothing l of
    Just x -> Just x
    Nothing -> case sl of
      Just p -> getVarInPattern p pos
      Nothing -> Nothing
getVarInPattern (HLIR.MkPatConstructor _ args) pos =
  foldr (\p acc -> getVarInPattern p pos <|> acc) Nothing args
getVarInPattern _ _ = Nothing

findLets 
  :: HLIR.TLIR "expression" 
  -> (Position, Uri) 
  ->  Maybe HLIR.Position 
  -> Map Text (HLIR.Type, Maybe CompletionItemKind)
findLets (HLIR.MkExprLet _ ann e) (pos, uri) p@(Just (start, end)) = do
  let Position line col = pos
  let pos' = SourcePos (fromMaybe "" (uriToFilePath uri)) (mkPos $ fromIntegral line + 1) (mkPos $ fromIntegral col + 1)

  let cond = pos' >= start 
          && pos' < end 
  
  let varDef = Map.singleton (HLIR.name ann) (runIdentity (HLIR.value ann), Nothing)

  if cond
    then findLets e (pos, uri) p <> varDef
    else if sourceName start /= fromMaybe "" (uriToFilePath uri)
      then varDef
      else mempty
findLets (HLIR.MkExprLet _ ann _) _ _ = 
  Map.singleton (HLIR.name ann) (runIdentity $ HLIR.value ann, Nothing)
findLets (HLIR.MkExprNative ann ty) _ _ = 
  Map.singleton (HLIR.name ann) (ty, Nothing)
findLets (HLIR.MkExprMut ann e) (pos, uri) p@(Just (start, end)) = do
  let Position line col = pos
  let pos' = SourcePos (fromMaybe "" (uriToFilePath uri)) (mkPos $ fromIntegral line + 1) (mkPos $ fromIntegral col + 1)

  let cond = pos' >= start 
          && pos' < end 

  let varDef = Map.singleton (HLIR.name ann) (runIdentity $ HLIR.value ann, Nothing)

  if cond
    then findLets e (pos, uri) p <> varDef
    else if sourceName start /= fromMaybe "" (uriToFilePath uri)
      then varDef
      else mempty
findLets (HLIR.MkExprMut ann _) _ _ = 
  Map.singleton (HLIR.name ann) (runIdentity $ HLIR.value ann, Nothing)
findLets (HLIR.MkExprLoc (HLIR.MkExprBlock es) p) pos _ =
  foldr (\e acc -> findLets e pos (Just p) <> acc) mempty es
findLets (HLIR.MkExprLoc e p'@(start, _)) pos p = case p of
  Just (_, end') -> findLets e pos (Just (start, end'))
  Nothing -> findLets e pos (Just p')
findLets (HLIR.MkExprLambda args _ body) p@(pos, uri) p'@(Just (start, end)) = do
  let Position line col = pos
  let pos' = SourcePos (fromMaybe "" (uriToFilePath uri)) (mkPos $ fromIntegral line + 1) (mkPos $ fromIntegral col + 1)

  let cond = pos' >= start 
          && pos' < end 
  let vars = Map.fromList $ map (\(HLIR.MkAnnotation name ty) -> (name, (runIdentity ty, Nothing))) args
  
  if cond
    then vars <> findLets body p p'
    else mempty
findLets (HLIR.MkExprLambda args _ body) p p' = do
  let vars = Map.fromList $ map (\(HLIR.MkAnnotation name ty) -> (name, (runIdentity ty, Nothing))) args

  vars <> findLets body p p'
findLets (HLIR.MkExprMatch e cs) pos p = do
  let vars = findLets e pos p
  let vars' = foldr (\(pat, expr, _) acc -> Map.map (, Nothing) (findLetsInPattern pat pos p) <> findLets expr pos p <> acc) mempty cs
  vars <> vars'
findLets (HLIR.MkExprTernary c t e) pos p = do
  let vars = findLets c pos p
  let vars' = findLets t pos p
  let vars'' = findLets e pos p
  vars <> vars' <> vars''
findLets (HLIR.MkExprBlock _) _ _ = error "Block not supported"
findLets (HLIR.MkExprApplication f args) pos p = do
  let vars = findLets f pos p
  let vars' = foldr (\e acc -> findLets e pos p <> acc) mempty args
  vars <> vars'
findLets (HLIR.MkExprActor ty events) pos p = do
  let vars = Map.singleton (toText ty) (ty, Just CompletionItemKind_Struct)
  let vars' = foldr (\e acc -> findLets e pos p <> acc) mempty events
  vars <> vars'
findLets (HLIR.MkExprList l) pos p = do
  let vars = foldr (\e acc -> findLets e pos p <> acc) mempty l
  vars
findLets (HLIR.MkExprOn ev args body) p@(pos, uri) p'@(Just (start, end)) = do
  let Position line col = pos
  let pos' = SourcePos (fromMaybe "" (uriToFilePath uri)) (mkPos $ fromIntegral line + 1) (mkPos $ fromIntegral col + 1)

  let cond = pos' >= start 
          && pos' < end 

  let vars = Map.fromList $ map (\(HLIR.MkAnnotation name ty) -> (name, (runIdentity ty, Nothing))) args
  let event = map (runIdentity . HLIR.value) args HLIR.:->: HLIR.MkTyUnit
  
  if cond 
    then vars <> findLets body p p' <> Map.singleton ev (event, Just CompletionItemKind_Event)
    else if sourceName start /= fromMaybe "" (uriToFilePath uri)
      then Map.singleton ev (event, Just CompletionItemKind_Event)
      else mempty
findLets (HLIR.MkExprWhile c b) pos p = do
  let vars = findLets c pos p
  let vars' = findLets b pos p
  vars <> vars'
findLets (HLIR.MkExprSend e _ args _) pos p = do
  let vars = findLets e pos p
  let vars' = foldr (\ex acc -> findLets ex pos p <> acc) mempty args
  vars <> vars'
findLets (HLIR.MkExprUpdate up val) pos p = do
  let vars = findLets val pos p
  case up of
    HLIR.MkUpdtVariable name -> vars <> Map.singleton (HLIR.name name) (runIdentity $ HLIR.value name, Nothing)
    _ -> vars
findLets _ _ _ = mempty

findLetsInPattern :: HLIR.TLIR "pattern" -> (Position, Uri) -> Maybe HLIR.Position -> Map Text HLIR.Type
findLetsInPattern (HLIR.MkPatVariable name ty) (pos, uri) (Just (start, end)) = do
  let Position line col = pos
  let pos' = SourcePos (fromMaybe "" (uriToFilePath uri)) (mkPos $ fromIntegral line + 1) (mkPos $ fromIntegral col + 1)

  let cond = pos' > start && pos' < end && sourceName start == fromMaybe "" (uriToFilePath uri)

  if cond
    then Map.singleton name (runIdentity ty)
    else mempty
findLetsInPattern (HLIR.MkPatLocated p (start, _)) ref (Just (_, end)) = do
  findLetsInPattern p ref (Just (start, end))
findLetsInPattern (HLIR.MkPatVariable name ty) _ _ = Map.singleton name (runIdentity ty)
findLetsInPattern (HLIR.MkPatLocated p _) ref p' = findLetsInPattern p ref p'
findLetsInPattern (HLIR.MkPatList l sl) pos p' = do
  let vars = foldr (\p acc -> findLetsInPattern p pos p' <> acc) mempty l
  case sl of
    Just p -> vars <> findLetsInPattern p pos p'
    Nothing -> vars
findLetsInPattern (HLIR.MkPatConstructor _ args) pos p' =
  foldr (\p acc -> findLetsInPattern p pos p' <> acc) mempty args
findLetsInPattern _ _ _ = mempty

parseURI :: (MonadIO m) => Uri -> m (Maybe [HLIR.TLIR "expression"])
parseURI uri = do
  let path = fromJust $ uriToFilePath uri
  let folder = takeDirectory path
      fileNameWithoutDir = dropExtension $ takeFileName path

  writeIORef moduleState $
    MkModuleState
      fileNameWithoutDir
      folder
      mempty
      mempty
      mempty
  moduleResult <- runExceptT $ resolve fileNameWithoutDir True

  case moduleResult of
    Left _ -> pure Nothing
    Right _ -> do
      preHLIR <- removeRequires <$> readIORef resultState

      typed <- runTypechecking preHLIR
      case typed of
        Left _ -> pure Nothing
        Right tlir -> pure $ Just tlir

findInterface :: HLIR.TLIR "expression" -> Text -> Maybe [HLIR.Annotation HLIR.Type]
findInterface (HLIR.MkExprInterface ann events) name | HLIR.name ann == name = Just events
findInterface (HLIR.MkExprLoc e _) name = findInterface e name
findInterface _ _ = Nothing

parseContentAndTypecheck :: MonadIO m => FilePath -> Text -> m (Either (Text, HLIR.Position) [HLIR.TLIR "expression"])
parseContentAndTypecheck path contents = do
  let folder = takeDirectory path
      fileNameWithoutDir = dropExtension $ takeFileName path

  writeIORef resultState []
  writeIORef moduleState $
    MkModuleState
      fileNameWithoutDir
      folder
      mempty
      mempty
      mempty
  moduleResult <- runExceptT $ resolveContent contents
  
  case moduleResult of
    Left (err, pos) -> pure $ Left (show err, pos)
    Right _ -> do
      preHLIR <- removeRequires <$> readIORef resultState

      typed <- runTypechecking preHLIR
      case typed of
        Left (err, pos) -> pure $ Left (show err, pos)
        Right tlir -> do
          writeIORef lastValidAST tlir
          pure $ Right tlir

parseAndTypecheck :: MonadIO m => FilePath -> m (Either (Text, HLIR.Position) [HLIR.TLIR "expression"])
parseAndTypecheck path = do
  let folder = takeDirectory path
      fileNameWithoutDir = dropExtension $ takeFileName path

  writeIORef resultState []
  writeIORef moduleState $
    MkModuleState
      fileNameWithoutDir
      folder
      mempty
      mempty
      mempty
  moduleResult <- runExceptT $ resolve fileNameWithoutDir True

  case moduleResult of
    Left (err, pos) -> pure $ Left (show err, pos)
    Right _ -> do
      preHLIR <- removeRequires <$> readIORef resultState

      typed <- runTypechecking preHLIR
      case typed of
        Left (err, pos) -> pure $ Left (show err, pos)
        Right tlir -> do
          writeIORef lastValidAST tlir
          pure $ Right tlir

handlers :: Handlers (LspM ())
handlers =
  mconcat
    [
        notificationHandler SMethod_Initialized $ \_not -> pure ()

      , notificationHandler SMethod_WorkspaceDidChangeConfiguration $ \_not -> pure ()

      , notificationHandler SMethod_TextDocumentDidOpen $ \req -> do
          let TNotificationMessage _ _ (DidOpenTextDocumentParams (TextDocumentItem uri _ _ _)) = req

          let path = fromJust $ uriToFilePath uri

          ast <- parseAndTypecheck path

          case ast of
            Left (err, (p1, p2)) -> do
              let (l1, c1) = (unPos (sourceLine p1), unPos (sourceColumn p1))
              let (l2, c2) = (unPos (sourceLine p2), unPos (sourceColumn p2))

              sendNotification SMethod_TextDocumentPublishDiagnostics $ PublishDiagnosticsParams uri Nothing [Diagnostic
                { _range = Range (Position (fromIntegral l1) (fromIntegral c1)) (Position (fromIntegral l2) (fromIntegral c2))
                , _severity = Just DiagnosticSeverity_Error
                , _code = Nothing
                , _source = Just "Bonzai"
                , _message = err
                , _relatedInformation = Nothing
                , _tags = Nothing
                , _data_ = Nothing
                , _codeDescription = Nothing
                }]
            Right _ -> do
              sendNotification SMethod_TextDocumentPublishDiagnostics $ PublishDiagnosticsParams uri Nothing []

      , notificationHandler SMethod_TextDocumentDidChange $ \req -> do
          let TNotificationMessage _ _ (DidChangeTextDocumentParams (VersionedTextDocumentIdentifier uri _) updates) = req
          
          -- Get updated text content

          let content = foldr (\(TextDocumentContentChangeEvent opt) acc -> case opt of
                  InR (TextDocumentContentChangeWholeDocument text) -> acc <> text
                  InL (TextDocumentContentChangePartial _ _ text) -> acc <> text
                ) "" updates
          let path = fromJust $ uriToFilePath uri

          ast <- parseContentAndTypecheck path content

          case ast of
            Left (err, (p1, p2)) -> do
              let (l1, c1) = (unPos (sourceLine p1), unPos (sourceColumn p1))
              let (l2, c2) = (unPos (sourceLine p2), unPos (sourceColumn p2))

              sendNotification SMethod_TextDocumentPublishDiagnostics $ PublishDiagnosticsParams uri Nothing [Diagnostic
                { _range = Range (Position (fromIntegral l1) (fromIntegral c1)) (Position (fromIntegral l2) (fromIntegral c2))
                , _severity = Just DiagnosticSeverity_Error
                , _code = Nothing
                , _source = Just "Bonzai"
                , _message = err
                , _relatedInformation = Nothing
                , _tags = Nothing
                , _data_ = Nothing
                , _codeDescription = Nothing
                }]
            Right _ -> do
              sendNotification SMethod_TextDocumentPublishDiagnostics $ PublishDiagnosticsParams uri Nothing []

      , requestHandler SMethod_TextDocumentHover $ \req responder -> do
          let TRequestMessage
                _
                _
                _
                (HoverParams (TextDocumentIdentifier uri) pos _workDone) = req
          let Position line col = pos

          tlir <- parseURI uri

          case tlir of
            Nothing -> responder (Right $ InR Null)
            Just tlir' -> do
              let vars = map (\e -> getVar e (pos, uri)) tlir'

              case catMaybes vars of
                [] -> responder (Right $ InR Null)
                (x:_) -> case x of
                  (name, ty) -> do
                    ty' <- HLIR.simplify ty
                    
                    let md = mkMarkdown 
                            $  "```bonzai\n"
                            <> name <> " : " <> toText ty' 
                            <> "\n```"

                    let range = Range
                          (Position line $ fromIntegral col)
                          (Position line $ fromIntegral col)
                    let rsp = Hover (InL md) (Just range)
                    responder (Right $ InL rsp)

      , requestHandler SMethod_TextDocumentCompletion $ \req responder -> do
          let TRequestMessage
                _
                _
                _
                (CompletionParams (TextDocumentIdentifier uri) pos@(Position line col) _ _ _)
                = req

          -- Get current text content with all unsaved modifications

          ast <- parseURI uri

          let completion label' kind detail =
                CompletionItem
                { _label = label'
                , _kind = Just kind
                , _detail = Just detail
                , _data_ = Nothing
                , _documentation = Nothing
                , _sortText = Nothing
                , _filterText = Nothing
                , _insertText = Nothing
                , _insertTextFormat = Nothing
                , _textEdit = Nothing
                , _additionalTextEdits = Nothing
                , _commitCharacters = Nothing
                , _command = Nothing
                , _tags = Nothing
                , _deprecated = Nothing
                , _preselect = Nothing
                , _labelDetails = Nothing
                , _insertTextMode = Nothing
                , _textEditText = Nothing
                }
        
          let filepath = fromJust $ uriToFilePath uri
          lines' <- Text.lines . decodeUtf8 <$> readFileLBS filepath

          let currentLine = lines' !! fromIntegral line
          let before = Text.take (fromIntegral col) currentLine
          let isArrow = Text.takeEnd 2 before == "->"
          let var = Text.takeWhileEnd Lex.isIdentChar (Text.dropEnd 2 before)
          let colStart = col - fromIntegral (Text.length var)

          ast' <- case ast of
                Nothing -> readIORef lastValidAST
                Just tlir -> pure tlir
            
          if isArrow then do
            let vars = mapMaybe (`getVar` (Position line colStart, uri)) ast'

            case vars of
              ((_, ty):_) -> do
                let (header, _) = decomposeHeader ty
                let interfaces = mapMaybe (`findInterface` header) ast'

                case interfaces of
                  (events:_) -> do
                    let completions = map (\(HLIR.MkAnnotation name ty') -> completion name CompletionItemKind_Event (toText ty')) events
                    responder $ Right $ InL completions
                  [] -> responder $ Right $ InL []

              []-> responder $ Right $ InL []
          else do
            let vars = Map.unions $ map (\e -> findLets e (pos, uri) Nothing) ast'
            vars' <- mapM (\(t, c) -> (,c) <$> HLIR.simplify t) vars

            let completions = Map.foldrWithKey (\k (v, c) acc -> completion k (case c of
                  Just c' -> c'
                  Nothing -> case v of
                    _ HLIR.:->: _ -> CompletionItemKind_Function
                    _ -> CompletionItemKind_Variable
                  ) (toText v) : acc) [] vars'

            responder $ Right $ InL completions

      , notificationHandler SMethod_TextDocumentDidSave $ \req -> do
          let TNotificationMessage _ _ (DidSaveTextDocumentParams (TextDocumentIdentifier uri) _) = req

          let path = fromJust $ uriToFilePath uri

          ast <- parseAndTypecheck path

          case ast of
            Left (err, (p1, p2)) -> do
              let (l1, c1) = (unPos (sourceLine p1), unPos (sourceColumn p1))
              let (l2, c2) = (unPos (sourceLine p2), unPos (sourceColumn p2))

              sendNotification SMethod_TextDocumentPublishDiagnostics $ PublishDiagnosticsParams uri Nothing [Diagnostic
                { _range = Range (Position (fromIntegral l1) (fromIntegral c1)) (Position (fromIntegral l2) (fromIntegral c2))
                , _severity = Just DiagnosticSeverity_Error
                , _code = Nothing
                , _source = Just "Bonzai"
                , _message = err
                , _relatedInformation = Nothing
                , _tags = Nothing
                , _data_ = Nothing
                , _codeDescription = Nothing
                }]
            Right _ -> do
              sendNotification SMethod_TextDocumentPublishDiagnostics $ PublishDiagnosticsParams uri Nothing []
    ]

syncOptions :: TextDocumentSyncOptions
syncOptions =
  TextDocumentSyncOptions
    { _openClose = Just True
    , _change = Just TextDocumentSyncKind_Full
    , _willSave = Just False
    , _willSaveWaitUntil = Just False
    , _save = Just $ InR $ SaveOptions $ Just True
    }

lspOptions :: Options
lspOptions =
  defaultOptions
    { optTextDocumentSync = Just syncOptions
    , optExecuteCommandCommands = Nothing
    }


main :: IO Int
main = do
  exitCode <- runServer $
    ServerDefinition
      { parseConfig = const $ const $ Right ()
      , onConfigChange = const $ pure ()
      , defaultConfig = ()
      , configSection = "demo"
      , doInitialize = \env _req -> pure $ Right env
      , staticHandlers = const handlers
      , interpretHandler = \env -> Iso (runLspT env) liftIO
      , options = lspOptions
      }
  exitWith $ ExitFailure exitCode