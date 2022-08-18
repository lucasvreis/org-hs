{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Org.Exporters.Pandoc where

import Control.Exception (throwIO)
import Ondim
import Ondim.Pandoc
import Org.Exporters.Common
import Paths_org_parser
import System.Directory.Recursive
import System.FilePath
import Text.Pandoc (def, readerExtensions, renderError, runPure)
import Text.Pandoc.Builder qualified as B
import Text.Pandoc.Definition qualified as P
import Text.Pandoc.Extensions (pandocExtensions)
import Text.Pandoc.Readers.Markdown (readMarkdown)

type PTag = PandocTag (State ExporterState)

instance ExportBackend PTag where
  type ObjectNode PTag = P.Inline
  nullObj = P.Str ""
  plain = toList . B.text
  softbreak = [P.SoftBreak]
  exportSnippet l = one . P.RawInline (P.Format l)
  type ElementNode PTag = P.Block
  nullEl = P.Null
  rawBlock l = one . P.RawBlock (P.Format l)
  hN level = fmap $ one . adjLevel level
    where
      adjLevel i (P.Header _ x z) = P.Header i x z
      adjLevel _ x = x
  mergeLists = (foldr go [] <$>)
    where
      go :: P.Block -> [P.Block] -> [P.Block]
      go (P.BulletList x) (P.BulletList y : r) = P.BulletList (x ++ y) : r
      go (P.OrderedList a x) (P.OrderedList b y : r) | a == b = P.OrderedList a (x ++ y) : r
      go (P.DefinitionList x) (P.DefinitionList y : r) = P.DefinitionList (x ++ y) : r
      go x y = x : y
  plainObjsToEls = one . P.Plain
  stringify = Ondim.Pandoc.stringify
  type DocumentNode PTag = P.Pandoc

newtype TemplateLoadingError = TemplateLoadingException String
  deriving (Eq, Show, Exception)

loadBlockTemplates :: IO (OndimS PTag P.Block)
loadBlockTemplates = do
  files <- getFilesRecursive . (</> "templates/md/blocks") =<< getDataDir
  templates <- forM files $ \file -> do
    text :: Text <- decodeUtf8 <$> readFileBS file
    let pandoc =
          runPure $
            readMarkdown def {readerExtensions = pandocExtensions} text
        name = takeBaseName file
    case pandoc of
      Left s -> throwIO (TemplateLoadingException (toString $ renderError s))
      Right t -> pure (fromString name, blockFromDocument t)
  pure $
    OndimS
      { expansions = fromList templates,
        filters = mempty
      }

loadInlineTemplates :: IO (OndimS PTag P.Inline)
loadInlineTemplates = do
  files <- getFilesRecursive . (</> "templates/md/inlines") =<< getDataDir
  templates <- forM files $ \file -> do
    text :: Text <- decodeUtf8 <$> readFileBS file
    let pandoc =
          runPure $
            readMarkdown def {readerExtensions = pandocExtensions} text
        name = takeBaseName file
    case pandoc of
      Left s -> throwIO (TemplateLoadingException (toString $ renderError s))
      Right t -> pure (fromString name, inlineFromDocument t)
  pure $
    OndimS
      { expansions = fromList templates,
        filters = mempty
      }
