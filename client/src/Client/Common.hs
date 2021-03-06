module Client.Common
  ( module Client.Common
  , module Annotate.Editor
  , module Reflex.Classes
  , Key
  ) where

import Annotate.Prelude hiding ((<>))
import Annotate.Common
import Annotate.Editor
import Annotate.Colour

import Control.Monad.Reader

import Data.Default
import Data.Semigroup
import Reflex.Classes

import qualified Data.Map as M
import qualified Data.Text as T

import Data.GADT.Compare.TH

import Language.Javascript.JSaddle (MonadJSM)
import Control.Lens (makePrisms)

import Web.KeyCode (Key)
import Text.Printf

import Linear.V3(V3(..))


type Builder t m = (Adjustable t m, MonadHold t m, DomBuilder t m, MonadFix m, PostBuild t m
                   , TriggerEvent t m, HasJSContext m, DomRenderHook t m, MonadIO (Performable m), MonadJSM (Performable m), MonadJSM m, DomBuilderSpace m ~ GhcjsDomSpace,  PerformEvent t m)

type AppEvent t = Event t [AppCommand]
type AppBuilder t m = (Builder t m, EventWriter t [AppCommand] m, MonadReader (AppEnv t) m)

type GhcjsBuilder t m = Builder t m
type GhcjsAppBuilder t m = AppBuilder t m

data ViewCommand
  = ZoomView Float Position
  | PanView Position Position
  deriving (Generic, Show)

data Dialog = ClassDialog DocParts
            | ErrorDialog ErrCode
            | SaveDialog (DocName, ImageCat) DocName

  deriving (Generic, Show)


data PrefCommand
  = ZoomBrush Float
  | SetOpacity Float
  | SetFontSize Int
  | SetBorder Float
  | SetGamma Float
  | SetBrightness Float
  | SetContrast Float

  | SetControlSize Float
  | SetInstanceColors Bool
  | ShowClass (ClassId, Bool)

  | SetNms Float
  | SetMinThreshold Float
  | SetDetections Int
  | SetThreshold Float
  | SetLowerThreshold Float
  
  | SetPrefs Preferences
  | SetSort SortCommand

  | SetAutoDetect Bool

  | SetAssignMethod AssignmentMethod
  | SetTrainRatio Int

  | SetShowConfidence Bool
  | SetReviewing Bool
   

  deriving (Generic, Show)


data SortCommand
  = SetSortKey SortKey
  | SetImageSelection ImageSelection
  | SetReverseSelection Bool
  | SetReverse Bool
  | SetFilter FilterOption
  | SetNegFilter Bool
  | SetSearch Text
  deriving (Generic, Show)


data AppCommand
  = ViewCmd ViewCommand
  | EditCmd EditCmd
  | SelectCmd DocParts
  | ClearCmd

  | SubmitCmd SubmitType
  | OpenCmd DocName (Maybe SubmitType)

  | ConfigCmd ConfigUpdate

  | DialogCmd Dialog
  | ClassCmd (Set AnnotationId) ClassId
  | PrefCmd PrefCommand
  | TrainerCmd UserCommand

  | NavCmd Navigation 

  deriving (Generic, Show)



data SceneEvent
  = SceneEnter
  | SceneLeave
  | SceneDown
  | SceneClick
  | SceneDoubleClick

    deriving (Generic, Show, Eq)

data Shortcut a where
  ShortCancel :: Shortcut ()
  ShortUndo   :: Shortcut ()
  ShortRedo   :: Shortcut ()
  ShortDelete :: Shortcut ()
  ShortSelect :: Shortcut Bool
  ShortArea      :: Shortcut ()
  ShortSelectAll :: Shortcut ()
  ShortClass     :: Shortcut ()
  ShortSetClass     :: Shortcut Int

type Cursor = Text


data Action = Action
  { cursor      :: Cursor
  , lock        :: Bool
  , edit        :: Maybe Edit
  } deriving (Generic, Eq, Show)

instance Default Action where
  def = Action
    { cursor = "default"
    , lock = False
    , edit = Nothing
    }

data AppEnv t = AppEnv
  { basePath :: Text
  , document :: (Dynamic t (Maybe Document))
  , editor :: (Dynamic t (Maybe Editor))
  , modified :: Dynamic t Bool

  , config :: (Dynamic t Config)
  , preferences :: (Dynamic t Preferences)
  , currentClass :: (Dynamic t ClassId)
  , docSelected  :: (Dynamic t (Maybe DocName))
  , shortcut     :: (EventSelector t Shortcut)
  , cancel       :: (Event t ())

  , selection    ::  (Dynamic t DocParts)
  , collection :: (Dynamic t Collection) 
  , loaded     :: Event t Document
  , detections :: Event t [Detection]
  , trainerStatus :: Dynamic t TrainerStatus

  , clock        :: Dynamic t UTCTime

  } deriving Generic



localPath :: MonadReader (AppEnv t) m => Text -> m Text
localPath path = do
  base <- asks basePath
  return $ base <> "/" <> path


imagePath :: MonadReader (AppEnv t) m => Text -> m Text
imagePath path = localPath ("images/" <> path)
  
newtype Shortcuts t = Shortcuts (forall a. Shortcut a -> Event t a)

askShortcuts :: (Reflex t, MonadReader (AppEnv t) m) => m (Shortcuts t)
askShortcuts = do
  selector <- view #shortcut
  return (Shortcuts (select selector))

askShortcut :: (Reflex t, MonadReader (AppEnv t) m) => Shortcut a -> m (Event t a)
askShortcut s = do
  (Shortcuts shortcut)  <- askShortcuts
  return $ shortcut s
  

askClasses :: AppBuilder t m => m (Dynamic t (Map ClassId ClassConfig))
askClasses = fmap (view #classes) <$> view #config


lookupClass :: AppBuilder t m => Dynamic t ClassId -> m (Dynamic t (Maybe ClassConfig))
lookupClass classId = do
  classes <- askClasses
  return $ M.lookup <$> classId <*> classes


docCommand :: AppBuilder t m => (a -> EditCmd) -> Event t a -> m ()
docCommand f = command (EditCmd . f)

viewCommand :: AppBuilder t m => Event t ViewCommand -> m ()
viewCommand = command ViewCmd

sortCommand :: AppBuilder t m => Event t SortCommand -> m ()
sortCommand = command (PrefCmd . SetSort)

prefCommand :: AppBuilder t m => Event t PrefCommand -> m ()
prefCommand = command PrefCmd

trainerCommand :: AppBuilder t m => Event t UserCommand -> m ()
trainerCommand = command TrainerCmd


editCommand :: AppBuilder t m => Event t Edit -> m ()
editCommand  = docCommand DocEdit

commands :: AppBuilder t m => (a -> AppCommand) -> Event t [a] -> m ()
commands f  = tellEvent . fmap (fmap f)


command :: AppBuilder t m => (a -> AppCommand) -> Event t a -> m ()
command f  = tellEvent . fmap (pure . f)

command' :: AppBuilder t m => AppCommand -> Event t a -> m ()
command' cmd = command (const cmd)


commandM :: AppBuilder t m => (a -> AppCommand) -> m (Event t a) -> m ()
commandM f m  = m >>= command f

commandM' :: AppBuilder t m => AppCommand -> m (Event t a) -> m ()
commandM' cmd = commandM (const cmd)

showText :: Show a => a -> Text
showText = T.pack . show

clearAnnotations :: EditCmd
clearAnnotations = DocEdit EditClearAll

printFloat :: Float -> Text
printFloat = T.pack . printf "%.2f"

printFloat0 :: Float -> Text
printFloat0 = T.pack . printf "%.0f"

makePrisms ''AppCommand
makePrisms ''SceneEvent

deriveGCompare ''Shortcut
deriveGEq ''Shortcut


