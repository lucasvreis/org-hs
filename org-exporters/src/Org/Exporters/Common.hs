{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Avoid lambda" #-}

module Org.Exporters.Common
  ( module Org.Exporters.Common,
    module Ondim,
  )
where

import Data.Map.Syntax
import Data.Text qualified as T
import Data.Time (Day, TimeOfDay (..), defaultTimeLocale, formatTime, fromGregorian)
import Ondim hiding (Expansion, Filter, Ondim, OndimMS)
import Ondim qualified
import Ondim.Extra
import Org.Data.Entities qualified as Data
import Org.Exporters.Processing.OrgData
import Org.Exporters.Processing.SpecialStrings (doSpecialStrings)
import Org.Types
import Paths_org_exporters (getDataDir)
import Relude.Extra (insert, lookup, toPairs)
import System.FilePath (isRelative, takeExtension, (-<.>), (</>))
import qualified Data.List as L

type ExporterMonad m = StateT ExporterState m

type Ondim tag m a = Ondim.Ondim tag (ExporterMonad m) a

type OndimMS tag m = Ondim.OndimMS tag (ExporterMonad m)

type Expansion tag m a = Ondim.Expansion tag (ExporterMonad m) a

type Filter tag m a = Ondim.Filter tag (ExporterMonad m) a

data ExporterState = ExporterState
  { footnoteCounter :: (Int, Map Text Int),
    linenumCounter :: Int,
    orgData :: OrgData
  }

data ExportBackend tag m obj elm = ExportBackend
  { nullObj :: obj,
    plain :: Text -> [obj],
    softbreak :: [obj],
    exportSnippet :: Text -> Text -> [obj],
    nullEl :: elm,
    srcPretty :: AffKeywords -> Text -> Text -> Ondim tag m (Maybe [[obj]]),
    affiliatedEnv :: AffKeywords -> Ondim tag m [elm] -> Ondim tag m [elm],
    rawBlock :: Text -> Text -> [elm],
    mergeLists :: Filter tag m elm,
    hN :: Int -> Expansion tag m elm,
    plainObjsToEls :: [obj] -> [elm],
    stringify :: obj -> Text,
    srcExpansionType :: Text,
    srcExpansion :: Text -> Ondim tag m [elm]
  }

templateDir :: IO FilePath
templateDir = (</> "templates") <$> getDataDir

initialExporterState :: ExporterState
initialExporterState =
  ExporterState
    { footnoteCounter = (1, mempty),
      linenumCounter = 1,
      orgData = initialOrgData
    }

getSetting :: Monad m => (ExporterSettings -> b) -> Ondim tag m b
getSetting f = f <$> gets (exporterSettings . orgData)

getFootnoteRef :: Monad m => Text -> Ondim tag m (Maybe (Text, [OrgElement]))
getFootnoteRef label =
  gets (lookup label . footnotes . orgData) >>= \case
    Just els -> do
      (i, m) <- gets footnoteCounter
      case lookup label m of
        Just num ->
          pure $ Just (show num, els)
        Nothing -> do
          modify \s -> s {footnoteCounter = (i + 1, insert label i m)}
          pure $ Just (show i, els)
    Nothing -> pure Nothing

justOrIgnore :: (OndimTag tag, Monad m) => Maybe a -> (a -> Expansion tag m b) -> Expansion tag m b
justOrIgnore = flip (maybe ignore)

tags :: forall m tag t. (HasAttrChild tag t, Monad m) => Tag -> Expansion tag m t
tags tag x = children x `bindingText` ("tag" ## pure tag)

bindAffKwExpansions ::
  BackendC tag m obj elm =>
  Ondim tag m [elm] ->
  (ExportBackend tag m obj elm, AffKeywords) ->
  Ondim tag m [elm]
bindAffKwExpansions x (bk, kws) =
  affiliatedEnv bk kws x
    `binding` do
      prefixed "akw:" $ forM_ parsedKws \(name, t) -> name ## const $ expandOrgObjects bk t
    `bindingText` do
      prefixed "akw:" $ forM_ textKws \(name, t) -> name ## pure t
  where
    parsedKws =
      mapMaybe
        (\case (n, ParsedKeyword _ t) -> Just (n, t); _ -> Nothing) -- TODO: first slot
        (toPairs kws)
    textKws =
      mapMaybe
        (\case (n, ValueKeyword t) -> Just (n, t); _ -> Nothing)
        (toPairs kws)

-- | Text expansion for link target.
linkTarget :: (OndimTag t, Monad m) => LinkTarget -> MapSyntax Text (Ondim t m Text)
linkTarget tgt = prefixed "link:" do
  "target" ## pure case tgt of
    URILink "file" (changeExtension -> file)
      | isRelative file -> toText file
      | otherwise -> "file:///" <> T.dropWhile (== '/') (toText file)
    URILink scheme uri -> scheme <> ":" <> uri
    InternalLink anchor -> "#" <> anchor
    UnresolvedLink tgt' -> tgt'
  case tgt of
    URILink scheme uri -> do
      "scheme" ## pure scheme
      "path" ## pure uri
      "extension" ## pure uri
    InternalLink {} -> "scheme" ## pure "internal"
    _ -> pure ()
  where
    changeExtension (toString -> file) =
      if takeExtension file == ".org"
        then file -<.> ".html"
        else file

type BackendC tag m obj elm =
  ( HasAttrChild tag obj,
    HasAttrChild tag elm,
    Monad m
  )

expandOrgObjects ::
  BackendC tag m obj elm =>
  ExportBackend tag m obj elm ->
  [OrgObject] ->
  Ondim tag m [obj]
expandOrgObjects = foldMapM . expandOrgObject

expandOrgObject ::
  forall tag m obj elm.
  BackendC tag m obj elm =>
  ExportBackend tag m obj elm ->
  OrgObject ->
  Ondim tag m [obj]
expandOrgObject bk@(ExportBackend {..}) obj =
  withText debugExps $
    case obj of
      (Plain txt) -> do
        specialStrings <- getSetting orgExportWithSpecialStrings
        pure $
          plain (if specialStrings then doSpecialStrings txt else txt)
      SoftBreak ->
        pure softbreak
      LineBreak ->
        call "org:object:linebreak"
      (Code txt) ->
        call "org:object:code"
          `bindingText` do "content" ## pure txt
      (Entity name) -> do
        withEntities <- getSetting orgExportWithEntities
        case lookup name Data.defaultEntitiesMap of
          Just (Data.Entity _ latex mathP html ascii latin utf8)
            | withEntities ->
                call "org:object:entity"
                  `binding` do
                    "entity:if-math" ## ifElse @obj mathP
                  `bindingText` do
                    "entity:latex" ## pure latex
                    "entity:ascii" ## pure ascii
                    "entity:html" ## pure html
                    "entity:latin" ## pure latin
                    "entity:utf8" ## pure utf8
          _ -> pure $ plain ("\\" <> name)
      (LaTeXFragment ftype txt) ->
        call "org:object:latex-fragment"
          `bindingText` do
            "content" ## pure txt
          `binding` do
            switchCases @obj $
              case ftype of
                InlMathFragment -> "inline"
                DispMathFragment -> "display"
                RawFragment -> "raw"
      (ExportSnippet backend code) ->
        pure $ exportSnippet backend code
      (Src lang _params txt) ->
        call "org:object:src"
          `bindingText` do
            "language" ## pure lang
            "content" ## pure txt
      (Target anchor name) ->
        call "org:object:target"
          `bindingText` do
            "anchor" ## pure anchor
      (Italic objs) ->
        call "org:object:italic"
          `binding` do
            "content" ## expObjs objs
      (Underline objs) ->
        call "org:object:underline"
          `binding` do
            "content" ## expObjs objs
      (Bold objs) ->
        call "org:object:bold"
          `binding` do
            "content" ## expObjs objs
      (Strikethrough objs) ->
        call "org:object:strikethrough"
          `binding` do
            "content" ## expObjs objs
      (Superscript objs) ->
        call "org:object:superscript"
          `binding` do
            "content" ## expObjs objs
      (Subscript objs) ->
        call "org:object:subscript"
          `binding` do
            "content" ## expObjs objs
      (Quoted qtype objs) ->
        call "org:object:quoted"
          `binding` do
            "content" ## expObjs objs
            switchCases
              case qtype of
                SingleQuote -> "single"
                DoubleQuote -> "double"
      (Verbatim txt) ->
        call "org:object:verbatim"
          `bindingText` do
            "content" ## pure txt
      (Link tgt objs) ->
        call "org:object:link"
          `bindingText` do
            linkTarget tgt
          `binding` do
            "content" ## expObjs objs
      (Image tgt) ->
        call "org:object:image"
          `bindingText` linkTarget tgt
      (Timestamp ts) ->
        timestamp bk ts
      (FootnoteRef (FootnoteRefLabel name)) -> do
        ref <- getFootnoteRef name
        call "org:object:footnote-ref"
          `binding` do
            whenJust ref \ ~(_, els) ->
              "footnote-ref:content" ## const $ expandOrgElements bk els
          `bindingText` do
            "footnote-ref:key" ## pure name
            whenJust ref \ ~(num, _) ->
              "footnote-ref:number" ## pure num
      (FootnoteRef _) -> pure []
      (Cite _) ->
        pure $ plain "(unresolved citation)" -- TODO
      (StatisticCookie c) ->
        call "org:object:statistic-cookie"
          & \x -> case c of
            Left (show -> n, show -> d) ->
              x
                `binding` switchCases @obj "fraction"
                `bindingText` do
                  "statistic-cookie:numerator" ## pure n
                  "statistic-cookie:denominator" ## pure d
                  "statistic-cookie:value" ## pure $ n <> "/" <> d
            Right (show -> p) ->
              x
                `binding` switchCases @obj "percentage"
                `bindingText` do
                  "statistic-cookie:percentage" ## pure p
                  "statistic-cookie:value" ## pure $ p <> "%"
      InlBabelCall {} ->
        error "TODO"
      Macro {} ->
        error "TODO"
  where
    debugExps =
      fromList
        [ ("debug:ast", pure (show obj))
        ]
    expObjs :: [OrgObject] -> Expansion tag m obj
    expObjs o = const $ expandOrgObjects bk o
    call x = callExpansion x (pure nullObj)

expandOrgElements ::
  BackendC tag m obj elm =>
  ExportBackend tag m obj elm ->
  [OrgElement] ->
  Ondim tag m [elm]
expandOrgElements = foldMapM . expandOrgElement

expandOrgElement ::
  forall tag m obj elm.
  BackendC tag m obj elm =>
  ExportBackend tag m obj elm ->
  OrgElement ->
  Ondim tag m [elm]
expandOrgElement bk@(ExportBackend {..}) el =
  withText debugExps $
    case el of
      (Paragraph aff [Image tgt]) ->
        call "org:element:figure"
          `bindingAff` aff
          `bindingText` linkTarget tgt
      (Paragraph aff c) ->
        call "org:element:paragraph"
          `bindingAff` aff
          `binding` ("content" ## const $ expandOrgObjects bk c)
      (GreaterBlock aff Quote c) ->
        call "org:element:quote-block"
          `bindingAff` aff
          `binding` do
            "content" ## expEls c
      (GreaterBlock aff Center c) ->
        call "org:element:center-block"
          `bindingAff` aff
          `binding` do
            "content" ## expEls c
      (GreaterBlock aff (Special cls) c) ->
        call "org:element:special-block"
          `bindingAff` aff
          `bindingText` do "special-name" ## pure cls
          `binding` do
            "content" ## expEls c
      (PlainList aff k i) ->
        plainList bk k i
          `bindingAff` aff
      (DynamicBlock _ _ els) ->
        expandOrgElements bk els
      (Drawer _ els) ->
        expandOrgElements bk els
      (ExportBlock lang code) ->
        pure $ rawBlock lang code
      (ExampleBlock aff switches c) ->
        srcOrExample bk "org:element:example-block" aff "" c
          `bindingAff` aff
          `bindingText` do
            "content" ## pure $ T.intercalate "\n" (srcLineContent <$> c)
      (SrcBlock _ lang _ props c)
        | lang == srcExpansionType,
          Just "t" == L.lookup "expand" props ->
            srcExpansion $
              T.intercalate "\n" (srcLineContent <$> c)
      (SrcBlock aff lang switches _ c) ->
        srcOrExample bk "org:element:src-block" aff lang c
          `bindingAff` aff
          `bindingText` do
            "language" ## pure lang
            "content" ## pure $ T.intercalate "\n" (srcLineContent <$> c)
      (LaTeXEnvironment aff _ text) ->
        call "org:element:latex-environment"
          `bindingAff` aff
          `bindingText` do "content" ## pure text
      (Table aff rs) ->
        table bk rs
          `bindingAff` aff
      HorizontalRule ->
        call "org:element:horizontal-rule"
      Keyword k v ->
        call "org:element:keyword"
          `bindingText` do
            "keyword:key" ## pure k
            "keyword:value" ## pure v
      FootnoteDef {} -> pure []
      VerseBlock {} -> error "TODO"
      Clock {} -> error "TODO"
  where
    debugExps =
      fromList
        [ ("debug:ast", pure (show el))
        ]
    bindingAff x aff = x `bindAffKwExpansions` (bk, aff)
    expEls :: [OrgElement] -> Expansion tag m elm
    expEls o = const $ expandOrgElements bk o
    call x = callExpansion x (pure nullEl)

expandOrgSections ::
  forall tag m obj elm.
  BackendC tag m obj elm =>
  ExportBackend tag m obj elm ->
  [OrgSection] ->
  Ondim tag m [elm]
expandOrgSections _ [] = pure []
expandOrgSections bk@(ExportBackend {..}) sections@(fstSection : _) = do
  let level = sectionLevel fstSection
  hlevels <- getSetting orgExportHeadlineLevels
  shift <- getSetting headlineLevelShift
  callExpansion "org:sections" (pure nullEl)
    `binding` do
      if level + shift > hlevels
        then switchCases @elm "over-level"
        else switchCases @elm "normal"
      "sections" ## \x ->
        mergeLists $
          join <$> forM sections \section@(OrgSection {..}) ->
            children x
              `binding` prefixed "section:" do
                "headline"
                  ## const
                  $ toList <$> expandOrgObjects bk sectionTitle
                "tags" ## \inner ->
                  join <$> forM sectionTags (`tags` inner)
              `binding` prefixed "section:" do
                "children" ## const $ toList <$> expandOrgElements bk sectionChildren
                "subsections" ## const $
                  withoutText "priority" $
                    withoutText "todo-state" $
                      withoutText "todo-name" $
                        expandOrgSections bk sectionSubsections
                "h-n" ## hN (sectionLevel + shift)
              `bindingText` prefixed "section:" do
                for_ sectionTodo todo
                for_ sectionPriority priority
                for_ (toPairs sectionProperties) \(k, v) ->
                  "prop:" <> k ## pure v
                "anchor" ## pure $ sectionAnchor
                -- Debug
                "debug:ast" ## pure (show section)
  where
    todo (TodoKeyword st nm) = do
      "todo-state" ## pure (todost st)
      "todo-name" ## pure nm
    todost Done = "done"
    todost Todo = "todo"
    priority p =
      "priority" ## pure case p of
        (LetterPriority c) -> T.singleton c
        (NumericPriority n) -> show n

liftDocument ::
  forall tag m obj elm doc.
  OndimNode tag doc =>
  BackendC tag m obj elm =>
  ExportBackend tag m obj elm ->
  OrgDocument ->
  doc ->
  Ondim tag m doc
liftDocument bk doc node =
  bindDocument bk "doc:" doc (liftSubstructures node)

bindDocument ::
  forall tag m obj elm doc.
  BackendC tag m obj elm =>
  ExportBackend tag m obj elm ->
  -- | Prefix for expansion names
  Text ->
  OrgDocument ->
  Ondim tag m doc ->
  Ondim tag m doc
bindDocument bk pfx (OrgDocument {..}) node = do
  datum <- gets orgData
  node
    `bindingText` prefixed pfx do
      forM_ (toPairs (keywords datum)) \(name, t) -> "kw:" <> name ## pure t
      forM_ (toPairs documentProperties) \(k, v) -> "prop:" <> k ## pure v
    `binding` prefixed pfx do
      "children" ## const $ expandOrgElements bk documentChildren
      "sections" ## const $ expandOrgSections bk documentSections
      "footnotes" ## \node' -> do
        fns <-
          gets (toPairs . snd . footnoteCounter)
            <&> mapMaybe \(ref, num) ->
              (,num) <$> lookup ref (footnotes datum)
        if not (null fns)
          then
            children node'
              `binding` do
                "footnote-defs" ## \inner ->
                  join <$> forM fns \(els, num) ->
                    children @elm inner
                      `bindingText` do
                        "footnote-def:number" ## pure (show num)
                      `binding` do
                        "footnote-def:content" ## const $ expandOrgElements bk els
          else pure []

table ::
  forall tag m obj elm.
  BackendC tag m obj elm =>
  ExportBackend tag m obj elm ->
  [TableRow] ->
  Ondim tag m [elm]
table bk@(ExportBackend {..}) rows =
  callExpansion "org:element:table" (pure nullEl)
    `binding` do
      "table:head" ## \inner ->
        fromMaybe (pure []) do
          rs <- tableHead
          pure $
            children inner `binding` do
              "head:rows" ## tableRows rs
      "table:bodies" ## tableBodies
  where
    (groups, props) = foldr go ([], []) rows
      where
        go (ColumnPropsRow p) ~(l, r) = (l, p : r)
        go (StandardRow cs) ~(l, r)
          | g : gs <- l = ((cs : g) : gs, r)
          | [] <- l = ([cs] : l, r)
        go RuleRow ~(l, r) = ([] : l, r)

    (tableHead, bodies) = case groups of
      [] -> (Nothing, [])
      [b] -> (Nothing, [b])
      h : b -> (Just h, b)

    tableBodies :: Expansion tag m elm
    tableBodies inner =
      mergeLists $
        join <$> forM bodies \body ->
          children inner `binding` do
            "body:rows" ## tableRows body

    tableRows :: [[TableCell]] -> Expansion tag m obj
    tableRows rs inner =
      join <$> forM rs \cells ->
        children inner
          `binding` do
            "row:cells" ## \inner' ->
              join <$> forM (zip cells alignment) \(row, alig) ->
                children @obj inner'
                  `binding` do
                    "cell:content" ## const $ expandOrgObjects bk row
                  `bindingText` for_ alig \a ->
                    "cell:alignment" ## pure case a of
                      AlignLeft -> "left"
                      AlignRight -> "right"
                      AlignCenter -> "center"

    alignment =
      (++ repeat Nothing) $
        fromMaybe [] $
          listToMaybe
            props

plainList ::
  forall tag m obj elm.
  BackendC tag m obj elm =>
  ExportBackend tag m obj elm ->
  ListType ->
  [ListItem] ->
  Ondim tag m [elm]
plainList bk@(ExportBackend {..}) kind items =
  callExpansion "org:element:plain-list" (pure nullEl)
    `binding` do
      "list-items" ## listItems
      case kind of
        Ordered OrderedNum -> switchCases "ordered-num"
        Ordered OrderedAlpha -> switchCases "ordered-alpha"
        Descriptive -> switchCases "descriptive"
        Unordered _ -> switchCases "unordered"
    `bindingText` case kind of
      Unordered b ->
        "bullet" ## pure (one b)
      _ -> mempty
  where
    listItems :: Expansion tag m elm
    listItems inner =
      mergeLists $
        join <$> forM items \(ListItem _ i cbox t c) ->
          children inner
            `bindingText` do
              "counter-set" ## pure $ maybe "" show i
              "checkbox" ## pure $ maybe "" checkbox cbox
            `binding` do
              "descriptive-tag" ## const $ expandOrgObjects bk t
            `binding` do
              "list-item-content" ## const $ doPlainOrPara c
      where
        doPlainOrPara :: [OrgElement] -> Ondim tag m [elm]
        doPlainOrPara [Paragraph _ objs] = plainObjsToEls <$> expandOrgObjects bk objs
        doPlainOrPara els = expandOrgElements bk els

        _start = join $ flip viaNonEmpty items \(ListItem _ i _ _ _ :| _) -> i

        -- adjFstF :: Filter tag ElementNode tag
        -- adjFstF = (map go <$>)
        --   where
        --     go (P.OrderedList (n, y, z) b) = P.OrderedList (fromMaybe n start, y, z) b
        --     go b = b

        checkbox :: Checkbox -> Text
        checkbox (BoolBox True) = "true"
        checkbox (BoolBox False) = "false"
        checkbox PartialBox = "partial"

srcOrExample ::
  forall tag m obj elm.
  BackendC tag m obj elm =>
  ExportBackend tag m obj elm ->
  Text ->
  AffKeywords ->
  Text ->
  [SrcLine] ->
  Ondim tag m [elm]
srcOrExample (ExportBackend {..}) name aff lang lins =
  callExpansion name (pure nullEl)
    `binding` ("src-lines" ## runLines)
    `bindingText` do
      "content" ## pure $ T.intercalate "\n" (srcLineContent <$> lins)
  where
    runLines :: Expansion tag m obj
    runLines inner = do
      cP <- contentPretty
      intercalate (plain "\n")
        <$> mapM (`lineExps` inner) (zip lins cP)

    contentPretty =
      let code = T.intercalate "\n" (srcLineContent <$> lins)
       in (++ repeat Nothing) . sequence <$> srcPretty aff lang code

    bPretty p = whenJust p \inls -> "content-pretty" ## const $ pure inls

    lineExps (SrcLine c, pretty) inner =
      switch "plain" inner
        `bindingText` do
          "content" ## pure c
        `binding` bPretty pretty
    lineExps (RefLine i ref c, pretty) inner =
      switch "ref" inner
        `bindingText` do
          "ref" ## pure ref
          "id" ## pure i
          "content" ## pure c
        `binding` bPretty pretty

timestamp ::
  forall tag m obj elm.
  BackendC tag m obj elm =>
  ExportBackend tag m obj elm ->
  TimestampData ->
  Ondim tag m [obj]
timestamp (ExportBackend {..}) ts =
  callExpansion "org:object:timestamp" (pure nullObj)
    `binding` case ts of
      TimestampData a (dateToDay -> d, fmap toTime -> t, r, w) -> do
        dtExps d t r w
        switchCases (active a <> "-single")
      TimestampRange
        a
        (dateToDay -> d1, fmap toTime -> t1, r1, w1)
        (dateToDay -> d2, fmap toTime -> t2, r2, w2) -> do
          "from" ## \x -> children x `binding` dtExps d1 t1 r1 w1
          "to" ## \x -> children x `binding` dtExps d2 t2 r2 w2
          switchCases @obj (active a <> "-range")
  where
    dtExps d t r w = do
      "repeater"
        ## justOrIgnore r \r' x -> children x `bindingText` tsMark r'
      "warning-period"
        ## justOrIgnore w \w' x -> children x `bindingText` tsMark w'
      "ts-date" ## tsDate d
      "ts-time" ## tsTime t

    active True = "active"
    active False = "inactive"

    tsMark :: TimestampMark -> MapSyntax Text (Ondim tag m Text)
    tsMark (_, v, c) = do
      "value" ## pure $ show v
      "unit" ## pure $ one c

    dateToDay (y, m, d, _) = fromGregorian (toInteger y) m d
    toTime (h, m) = TimeOfDay h m 0

    tsDate :: Day -> Expansion tag m obj
    tsDate day input' = do
      input <- input'
      let format = toString $ stringify input
          locale = defaultTimeLocale -- TODO
      pure . plain . toText $ formatTime locale format day

    tsTime :: Maybe TimeOfDay -> Expansion tag m obj
    tsTime time input' = do
      input <- input'
      let format = toString $ stringify input
          locale = defaultTimeLocale -- TODO
      maybe (pure []) (pure . plain . toText . formatTime locale format) time
