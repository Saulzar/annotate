module Client.Images where

import Annotate.Prelude hiding (div)
import qualified Annotate.Prelude as Prelude

import Annotate.Common hiding (label)

import Client.Common
import Client.Widgets
import Client.Select

import Data.Ord (comparing, Ordering(..))
import Data.List (sortBy, findIndex)

import qualified GHC.Real as Real

import Builder.Html
import qualified Builder.Html as Html

import qualified Data.Map as M
import qualified Data.Text as T

import Data.Time.Format.Human 

fixed :: Reflex t => Int -> Property t
fixed n = style_ =: 
  [ ("width", showText n <> "%"), ("vertical-align", "middle") ]
  -- , ("padding-top", "0"), ("padding-bottom", "0"), ("border", "0")]



showHeader :: AppBuilder t m => Dynamic t SortOptions -> m ()
showHeader opts = tr [] $ do
    th [fixed 60] $ text "File"
    key <- th [fixed 40] $ 
      selectView allSorts (view #sortKey <$> opts)

    rev <- toggleButtonView ("sort-descending", "sort-ascending") (view #reversed <$> opts)

    sortCommand (SetSortKey <$> key)
    sortCommand (SetReverse <$> rev)      

    return ()
      where
        width n = style_ =: [("width", showText n <> "%")]
  
approxLocale :: HumanTimeLocale
approxLocale = defaultHumanTimeLocale 
  { justNow = "within a minute" 
  , secondsAgo = const (const "within a minute")
  }

showTime :: UTCTime -> Maybe UTCTime -> Text
showTime current = fromMaybe "never" . fmap (fromString . humanReadableTimeI18N' approxLocale current)

showModified :: AppBuilder t m => Dynamic t DocInfo -> m ()
showModified info = do
  now <- view #clock
  dynText (showTime <$> now <*> (view #modified <$> info))


showField :: AppBuilder t m => Dynamic t (DocName, DocInfo) -> SortKey ->  m ()
showField d key  = case key of
    SortName     -> return () -- dynText name
    SortRandom   -> return ()--dynText (showText . unHash . view #hashedName <$> info)
    SortCategory     -> dynText (showText . view #category <$> info)
    SortModified     -> showModified info

    SortAnnotations  -> dynText (showText . view #numAnnotations <$> info)
    SortDetections  -> dynText (fromMaybe "" . fmap printFloat . detectionScore <$> info)

    SortLossMean    -> dynText (printFloat . view (#training . #lossMean) <$> info)
    SortLossMax     -> dynText (printFloat . view (#training . #lossMax) <$> info)
    where
      (name, info) = split d


showImage :: AppBuilder t m =>  SortKey ->  Dynamic t (Maybe (DocName, DocInfo)) -> Dynamic t Bool -> m (Event t DocName)
showImage sortKey maybeRow selected = do
  e <- tr_ [rowClasses] $ do 
    td [fixed 60] $ centreRow $ do
      smallIcon (Dyn $ categoryIcon' . view #category <$> info)
      span [class_ =: "pt-1"] $ dynText name
      preload name

    td [fixed 40] $ do 
      showField imageInfo sortKey
    
  return (current name `tag` domEvent Click e)

    where
      rowClasses = classList [gated "table-active" selected, gated "invisible" (isNothing <$> maybeRow)]     
      imageInfo = fromMaybe def <$> maybeRow
      (name, info) = split imageInfo
      

allSelection :: [(Text, ImageSelection)]
allSelection =
  [ ("forwards",     SelSequential False)
  , ("backwards",     SelSequential True)
  , ("random",     SelRandom)
  , ("most detections",     SelDetections False)
  , ("large train error",     SelLoss)
  , ("least detections",     SelDetections True)
  ]

allFilters :: [(Text, FilterOption)]
allFilters =
  [ ("all",     FilterAll)
  , ("new",     FilterCat CatNew)
  , ("train",   FilterCat CatTrain)
  , ("validate",    FilterCat CatValidate)
  , ("discard", FilterCat CatDiscard)
  , ("edited",  FilterEdited)
  ]


allSorts :: [(Text, SortKey)] 
allSorts = 
  [ ("name",     SortName)
  , ("category", SortCategory)
  , ("modified", SortModified)
  , ("annotations", SortAnnotations)
  , ("detection score", SortDetections)
  , ("mean error", SortLossMean)
  , ("max error", SortLossMax)
  , ("random", SortRandom)
  ]


enabled_ :: Attribute Bool
enabled_ = contramap not disabled_


imagesTab :: forall t m. AppBuilder t m => m ()
imagesTab = sidePane $ do
  selected    <- view #docSelected
  images      <- fmap (view #images) <$> view #collection
  prefs       <- view #preferences 

  let opts  = view #sortOptions <$> prefs
      sorted = sortImages <$> opts <*> (M.toList <$> images)
      

  column "v-spacing-2 p-2 border h-100" $ do
    centreRow $ do
      searched <- div [class_ =: "input-group grow-3"] $ searchView (view #search <$> opts)
      neg <- toggleButtonView ("not-equal-variant", "equal") (view #negFilter <$> opts)
  
      filtered <- grow $ selectView allFilters (view #filtering <$> opts)
      
      sortCommand (SetSearch <$> searched)
      sortCommand (SetFilter <$> filtered)
      sortCommand (SetNegFilter <$> neg)
  
    imageList 10 opts selected sorted

    spacer

    imgSelection <- labelled "Example selection" $ selectView allSelection (view #selection <$> opts)
    sortCommand (SetImageSelection <$> imgSelection)


    where 
      maybeLookup selected m = do 
        k <- selected
        info <- M.lookup k m
        return (k, info)
       
       

findOffset :: Int -> [(DocName, DocInfo)] -> Maybe DocName -> Int
findOffset size images selected = fromMaybe 0 $ do
  k <- selected
  i <- findIndex ((== k) . fst) images
  return $ (i `Prelude.div` size) * size


inputView' :: forall t m. Builder t m => [Property t] -> Dynamic t Text -> m (Event t Text)
inputView' props =  toView $ \setText -> _inputElement_value <$> 
  inputElem props (def & inputElementConfig_setValue .~ setText)

searchView :: forall t m. Builder t m => Dynamic t Text -> m (Event t Text)
searchView = inputView' [ class_ =: "form-control", type_ =: "search", placeholder_ =: "Search..." ]




navControl :: forall t m. Builder t m => Int -> Dynamic t Int -> Dynamic t Int -> m (Event t (Int -> Int))
navControl size numImages offset = row "justify-content-between align-items-center" $ do
    (start, dec) <- buttonGroup $ liftA2 (,)
      (navButton enablePrev $  icon "chevron-double-left")
      (navButton enablePrev $  icon "chevron-left")

    span [] $ dynText (showPage <$> offset <*> numImages)  

    (inc, end) <- buttonGroup $ liftA2 (,)
      (navButton enableNext $ icon "chevron-right")
      (navButton enableNext $ icon "chevron-double-right")

    return $ leftmost
      [ (+size) <$ inc
      , (subtract size) <$  dec
      , const 0 <$ start 
      , toEnd <$> current numImages `tag` end
      ]

  where
    toEnd n = const (n - 1)

    enablePrev = (> 0) <$> offset
    enableNext = hasNext <$> offset <*> numImages
      where hasNext i n = (i + size < n)

    navButton enabled = fmap (domEvent Click) <$> 
      button_ [class_ =: "btn btn-outline", enabled_  ~: enabled ]     

    showPage i images = showText (pageNum i) <> " of " <> showText (pageNum images)
    pageNum i = i `Real.div` size + 1    
  

imageList :: forall t m. AppBuilder t m 
          => Int 
          
          -> Dynamic t SortOptions
          -> Dynamic t (Maybe DocName) -> Dynamic t [(DocName, DocInfo)] 
          -> m ()

imageList size  opts selected images = do   
  rec
    offset <- holdDyn 0 $ leftmost
      [ updated (findOffset size <$> images <*> selected)
      , attachWith (&) (current offset) updatePage
      ]
   
    userSelect <- table [class_ =: "table table-sm table-hover"] $ do
      thead [] $ showHeader opts

      tbody [class_ =: "scroll"] $ 
        dyn' never $ ffor (view #sortKey <$> opts) $ \k -> 
          selectPaged (pure size) offset images (showImage k) selected

    updatePage <- navControl size (length <$> images) offset
  command OpenCmd userSelect

   





categoryIcon :: forall t. Reflex t => ImageCat -> IconConfig t
categoryIcon cat = (def :: IconConfig t) & #name .~ Static (categoryIcon' cat)

categoryIcon' :: ImageCat -> Text
categoryIcon' CatDiscard   = "delete-empty"
categoryIcon' CatValidate  = "clipboard-check" 
categoryIcon' CatNew       = "image-outline"
categoryIcon' CatTrain     = "book-open-page-variant" 
      