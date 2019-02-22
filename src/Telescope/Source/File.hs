{-# LANGUAGE DeriveGeneric #-}

-- | A naive file-based data source.
module Telescope.Source.File where

import           Control.Concurrent.MVar    (MVar, modifyMVar_, newMVar,
                                             readMVar, swapMVar)
import           Control.Exception          (catch, throwIO)
import           Control.Monad              (void, when)
import           Control.Monad.IO.Class     (MonadIO, liftIO)
import           Data.ByteString.Char8      (ByteString, pack, unpack)
import           Data.Either.Extra          (fromRight')
import           Data.Map                   (Map)
import qualified Data.Map                   as Map
import           Data.Serialize             (Serialize, decode, encode)
import           GHC.Generics               (Generic)
import           System.Directory           (canonicalizePath)
import           System.FilePath            (takeDirectory)
import           System.FSNotify            (Event (Modified))
import qualified System.FSNotify            as FS
import           System.IO.Error            (isDoesNotExistError)
import qualified System.IO.Strict           as Strict

import           Telescope.Monad            (runScope)
import           Telescope.Operations       (runHandlersS)
import           Telescope.Source           (RmAllS, SetAllS, Source (..),
                                             SourceConfig (..), ViewAllS)
import qualified Telescope.Source.Shortcuts as Shortcuts
import           Telescope.Storable         (RowKey, TableKey (..))

data MetaData = MetaData {
    _metaDataUpdatesPaths :: [FilePath]
  } deriving Generic

instance Serialize MetaData

-- | Functions to operate on a file-based data source.
file :: IO (Source IO)
file = do
  metaDataMVar <- newMVar $ encode $ MetaData []
  pure Source {
    _sourceName          = "file"
  , _sourceRmAllS        = rmAllS
  , _sourceRmS           = Shortcuts.rmS viewAllS setAllS
  , _sourceSetAllS       = setAllS
  , _sourceSetS          = Shortcuts.setS viewAllS setAllS
  , _sourceViewAllS      = viewAllS
  , _sourceViewS         = Shortcuts.viewS viewAllS
  , _sourceEmitUpdatesS  = emitUpdatesS
  , _sourceWatchUpdatesS = watchUpdatesS
  , _sourceMetaDataMVar  = metaDataMVar
  }

-- | A configuration to operate on a file-based data source.
fileConfig :: FilePath -> IO (SourceConfig IO)
fileConfig path = do
  fileSource   <- file
  handlersMVar <- newMVar []
  pure SourceConfig {
      path     = path
    , source   = fileSource
    , handlers = handlersMVar
    , hostPort = Nothing
    }

viewAllS :: ViewAllS IO
viewAllS config tk = do
  tablePath <- liftIO $ tableCanonPath tk (path config)
  liftIO $ readOrDefault Map.empty tablePath

setAllS :: SetAllS IO
setAllS config tk table = do
  tablePath <- liftIO $ tableCanonPath tk (path config)
  liftIO $ writeFile tablePath $ unpack $ encode table

rmAllS :: RmAllS IO
rmAllS config tk = setAllS config tk Map.empty

emitUpdatesS :: SourceConfig IO -> TableKey -> Map RowKey ByteString -> IO ()
emitUpdatesS config tk updates = do
  updatesPath <- liftIO $ updatesCanonPath tk $ path config
  Updates lastUpdates@((lastID, _) : _) <- readOrDefault defUpdates updatesPath
  writeFile updatesPath $ unpack $ encode $
    Updates $ (lastID + 1, updates) : lastUpdates

-- | TODO: Move to Set.
readUpdatesPaths :: SourceConfig IO -> IO [FilePath]
readUpdatesPaths config = do
  let metaDataMVar = _sourceMetaDataMVar $ source $ config
  bs <- readMVar metaDataMVar
  pure $ fromRight' $ decode bs

addToUpdatesPaths :: FilePath -> SourceConfig IO -> IO ()
addToUpdatesPaths newPath config = do
  let metaDataMVar = _sourceMetaDataMVar $ source $ config
  modifyMVar_ metaDataMVar $ \bs -> do
    let metaData@(MetaData paths) = fromRight' $ decode bs :: MetaData
    pure $ encode $ metaData { _metaDataUpdatesPaths = newPath : paths }

watchUpdatesS :: SourceConfig IO -> TableKey -> RowKey -> IO ()
watchUpdatesS config tk rk = do

  -- Path of file containing: updates for current table.
  updatesPath <- liftIO $ updatesCanonPath tk $ path config

  -- Only subscribe to the file if not already subscribed.
  updatesPaths <- liftIO $ readUpdatesPaths config

  when (updatesPath `notElem` updatesPaths) $ void $ liftIO $ do

    -- Read the ID of the last update on file.
    Updates ((lastID, _):_) <- readOrDefault defUpdates updatesPath

    -- Record the ID of next expected update.
    lastIDMVar <- newMVar lastID

    -- Subscribe to any subsequent updates.
    subscribeToUpdatesFile updatesPath tk lastIDMVar config

-- | Watch a file for updates and run update handlers.
subscribeToUpdatesFile ::
  FilePath -> TableKey -> MVar Int -> SourceConfig IO -> IO ()
subscribeToUpdatesFile updatePath tk lastIDMVar config = do

  addToUpdatesPaths updatePath config

  -- True if given 'fn' is modified.
  let moddedFile fn (Modified fnChange _ _) = fn == fnChange
      moddedFile _ _                        = False

  -- Whenever the update file is modified..
  manager <- FS.startManager
  void $ FS.watchDir manager (takeDirectory updatePath)
    (moddedFile updatePath) $ const $ void $ do

    -- Read the new updates on modification.
    Updates updates@((newLastID, _):_) <- readOrDefault defUpdates updatePath

    -- Find ID of the last read update, and record ID of newly read updates.
    lastID <- swapMVar lastIDMVar newLastID

    -- Run handlers for all newly read updates.
    runScope config $ sequence $ concat [[
      runHandlersS tk k v
      | (k, v)      <- Map.toList table             ]
      | (id, table) <- reverse updates, id > lastID ]

canonPath tkS name extension =
  canonicalizePath $ "./" ++ name ++ tkS ++ extension

tableCanonPath   (TableKey tkS) name = canonPath tkS name ".db"

updatesCanonPath (TableKey tkS) name = canonPath tkS name ".updates"

-- | A set of updates for a table, each associated with an ID.
newtype Updates = Updates [(Int, Map RowKey ByteString)]
  deriving (Generic, Show)

instance Serialize Updates

-- | Value returned from an empty updates file.
defUpdates = Updates [(0, Map.empty)]

-- | Read and decode a value of type 'a' from a file.
--
-- In-case of a file-not-found error return the default value.
readOrDefault :: Serialize a => a -> FilePath -> IO a
readOrDefault default' updatesPath =
  flip catch catchDoesNotExistError $ do
    fromRight' . decode . pack <$> Strict.readFile updatesPath
  where catchDoesNotExistError e
          | isDoesNotExistError e = pure default'
          | otherwise             = throwIO e
