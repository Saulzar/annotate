module Annotate.Editor where

import Annotate.Prelude

import qualified Data.Map as M
import qualified Data.Set as S

import Annotate.Common

import Data.List (uncons)
import Data.Maybe (catMaybes)

import Control.Lens hiding (uncons, without)
import Data.List.NonEmpty (nonEmpty)

import Data.Align
import Data.These

import Control.Lens (makePrisms)

import Debug.Trace


type DocPart = (AnnotationId, Maybe Int)

mergeParts :: DocParts -> DocParts -> DocParts
mergeParts = M.unionWith mappend


-- DocumentPatch' is a non invertible version of DocumentPatch (less details)
-- used for patching the AnnotationMap to update the view.
data DocumentPatch'
  = PatchAnns' (Map AnnotationId (Maybe Annotation))
  | PatchArea' (Maybe Box)
     deriving (Show, Eq, Generic)


-- data OpenMethod = OpenReview [Detections] | OpenNew [Detections] | OpenEdit
--   deriving (Eq, Enum, Generic, Show)

-- instance Show OpenType where
--   show OpenReview = "Review"
--   show OpenNew    = "New"
--   show OpenEdit   = "Edit"

data Editor = Editor
  { name  :: DocName
  , undos :: [DocumentPatch]
  , redos :: [DocumentPatch]
  , annotations :: AnnotationMap
  , validArea :: Maybe Box
  , history :: [(UTCTime, HistoryEntry)]
  } deriving (Generic, Show, Eq)

makePrisms ''DocumentPatch'
makePrisms ''EditCmd
makePrisms ''DocumentPatch

isModified :: Editor -> Bool
isModified = not . null . view #undos

newDetection :: Detection -> Annotation
newDetection d@Detection{..} = Annotation{..}
    where detection = Just (Detected, d) 

fromDetections :: AnnotationId -> [Detection] -> AnnotationMap
fromDetections i detections = M.fromList (zip [i..] $ newDetection <$> detections) where
  
missedDetection :: Detection -> Annotation
missedDetection d@Detection{..} = Annotation {..}
    where detection = Just (Missed, d) 

reviewDetections :: [Detection] -> AnnotationMap -> AnnotationMap 
reviewDetections = flip (foldr addReview) where

  addReview d = case d ^. #match of
    Just i  -> M.adjust (setReview d) i
    Nothing -> insertAuto (missedDetection d)

  setReview d = #detection .~ Just (Review, d)
    
insertAuto :: (Ord k, Num k) => a -> Map k a -> Map k a
insertAuto a m = M.insert k a m
    where k = 1 + fromMaybe 0 (maxKey m)


editDocument :: Document -> Editor
editDocument Document{..} = Editor
    { name 
    , annotations = fromBasic <$> annotations
    , validArea
    , history = []
    , undos = []
    , redos = []
    } 
    
       

thresholdDetection :: Float -> Annotation -> Bool
thresholdDetection t Annotation{detection} = case detection of 
  Just (tag, Detection{confidence}) -> 
          tag == Detected && confidence >= t 
          || tag == Confirmed
          || tag == Review

  Nothing -> True

  

allAnnotations :: Editor -> [AnnotationId]
allAnnotations Editor{annotations} = M.keys annotations

lookupAnnotations :: [AnnotationId] -> Editor -> AnnotationMap
lookupAnnotations objs Editor{annotations} = M.fromList $ catMaybes $ fmap lookup' objs
    where lookup' k = (k, ) <$> M.lookup k annotations


maxEdits :: [DocumentPatch] -> Maybe AnnotationId
maxEdits =  maybeMaximum . fmap maxEdit

maxEdit :: DocumentPatch -> Maybe AnnotationId
maxEdit (PatchAnns e) = maxKey e
maxEdit _        = Nothing


maybeMaximum :: (Ord k) => [Maybe k] -> Maybe k
maybeMaximum = fmap maximum . nonEmpty . catMaybes

maxId :: Editor -> Maybe AnnotationId
maxId Editor{..} = maybeMaximum
  [ maxEdits undos
  , maxEdits redos
  , maxKey annotations
  ]

nextId :: Editor -> AnnotationId
nextId = fromMaybe 0 .  fmap (+1) . maxId


subParts :: Editor -> AnnotationId -> Set Int
subParts doc k = fromMaybe mempty $  do
  ann <- M.lookup k (doc ^. #annotations)
  return $ shapeParts (ann ^. #shape)

documentParts :: Editor -> DocParts
documentParts = fmap (shapeParts . view #shape) . view #annotations

shapeParts :: Shape -> Set Int
shapeParts = \case
    ShapeBox _                  -> S.fromList [0..3]
    ShapeCircle _               -> S.singleton 0
    ShapeLine (WideLine points)   -> S.fromList [0..length points]
    ShapePolygon (Polygon points) -> S.fromList [0..length points]


lookupTargets :: Editor -> [AnnotationId] -> Map AnnotationId (Maybe Annotation)
lookupTargets Editor{annotations} targets = M.fromList modified where
  modified = lookup' annotations <$> targets
  lookup' m k = (k, M.lookup k m)

applyCmd :: EditCmd -> Editor -> Editor
applyCmd cmd doc = fromMaybe doc (snd <$> applyCmd' cmd doc)

applyCmd' :: EditCmd -> Editor -> Maybe (DocumentPatch', Editor)
applyCmd' DocUndo doc = applyUndo doc
applyCmd' DocRedo doc = applyRedo doc
applyCmd' (DocEdit e) doc = applyEdit e doc


maybePatchDocument :: Maybe DocumentPatch' -> Editor -> Editor
maybePatchDocument Nothing  = id
maybePatchDocument (Just p) = patchDocument p

patchDocument :: DocumentPatch' -> Editor -> Editor
patchDocument (PatchAnns' p)  = over #annotations (patchMap p)
patchDocument (PatchArea' b) = #validArea .~ b


applyEdit :: Edit -> Editor -> Maybe (DocumentPatch', Editor)
applyEdit e doc = do
  (inverse, patch) <- patchInverse doc (editPatch e doc)
  return (patch, patchDocument patch doc
    & #redos .~ mempty
    & #undos %~ (inverse :))


applyUndo :: Editor -> Maybe (DocumentPatch', Editor)
applyUndo doc = do
  (e, undos) <- uncons (doc ^. #undos)
  (inverse, patch) <- patchInverse doc e
  return (patch, patchDocument patch doc
    & #undos .~ undos
    & #redos %~ (inverse :))


applyRedo :: Editor -> Maybe (DocumentPatch', Editor)
applyRedo doc = do
  (e, redos) <- uncons (doc ^. #redos)
  (inverse, patch) <- patchInverse doc e
  return (patch, patchDocument patch doc
    & #redos .~ redos
    & #undos %~ (inverse :))


toEnumSet :: forall a. (Bounded a, Enum a, Ord a) => Set Int -> Set a
toEnumSet = S.mapMonotonic toEnum . S.filter (\i -> i >= lower && i <= upper)
  where (lower, upper) = (fromEnum (minBound :: a), fromEnum (maxBound :: a))


transformBoxParts :: Rigid -> Set Int -> Box -> Box
transformBoxParts rigid parts = transformCorners rigid (toEnumSet parts)

sides :: Set Corner -> (Bool, Bool, Bool, Bool)
sides corners =
    (corner TopLeft     || corner BottomLeft
    , corner TopRight    || corner BottomRight
    , corner TopLeft     || corner TopRight
    , corner BottomLeft  || corner BottomRight
    ) where corner = flip S.member corners

transformCorners :: Rigid -> Set Corner -> Box -> Box
transformCorners (s, V2 tx ty) corners = translateBox  . scaleBox scale where
  scale = V2 (if left && right then s else 1)
             (if top && bottom then s else 1)

  translateBox (Box (V2 lx ly) (V2 ux uy)) = getBounds
    [ V2 (lx + mask left * tx) (ly + mask top * ty)
    , V2 (ux + mask right * tx) (uy + mask bottom * ty)
    ]

  mask b = if b then 1 else 0
  (left, right, top, bottom) = sides corners


_subset indexes = traversed . ifiltered (const . flip S.member indexes)

_without indexes = traversed . ifiltered (const . not . flip S.member indexes)


subset :: Traversable f => Set Int -> f a -> [a]
subset indexes f = toListOf (_subset indexes) f

without :: Traversable f => Set Int -> f a -> [a]
without indexes f = toListOf (_without indexes) f



transformPoint :: Position -> Rigid -> Position -> Position
transformPoint centre (s, t) =  (+ t) . (+ centre) . (^* s) . subtract centre


transformVertices :: Rigid -> NonEmpty Position -> NonEmpty Position
transformVertices  rigid points = transformPoint centre rigid <$> points
    where centre = boxCentre (getBounds points)


transformPolygonParts :: Rigid -> Set Int -> Polygon -> Polygon
transformPolygonParts rigid indexes (Polygon points) = Polygon $ fromMaybe points $ do
  centre <- boxCentre . getBounds <$> nonEmpty (subset indexes points)
  return  (over (_subset indexes) (transformPoint centre rigid) points)


transformLineParts :: Rigid -> Set Int -> WideLine -> WideLine
transformLineParts rigid indexes (WideLine circles) =  WideLine $
  over (_subset indexes) (transformCircle rigid) circles


transformCircle :: Rigid -> Circle -> Circle
transformCircle (s, t) (Circle p r) = Circle (p + t) (r * s)

transformBox :: Rigid -> Box -> Box
transformBox (s, t) = over boxExtents
  (\Extents{..} -> Extents (centre + t) (extents ^* s))


transformShape :: Rigid -> Shape -> Shape
transformShape rigid = \case
  ShapeCircle c      -> ShapeCircle       $ transformCircle rigid c
  ShapeBox b      -> ShapeBox       $ transformBox rigid b
  ShapePolygon poly -> ShapePolygon $ poly & over #points (transformVertices rigid)
  ShapeLine line -> ShapeLine       $ line & over #points (fmap (transformCircle rigid))


transformParts :: Rigid -> Set Int -> Shape -> Shape
transformParts rigid parts = \case
  ShapeCircle c      -> ShapeCircle $ transformCircle rigid c
  ShapeBox b        -> ShapeBox     $ transformBoxParts rigid parts b
  ShapePolygon poly -> ShapePolygon $ transformPolygonParts rigid parts poly
  ShapeLine line    -> ShapeLine    $ transformLineParts rigid parts line



deleteParts :: Set Int -> Shape -> Maybe Shape
deleteParts parts = \case
  ShapeCircle _     -> Nothing
  ShapeBox _        -> Nothing
  ShapePolygon (Polygon points)  -> ShapePolygon . Polygon <$> nonEmpty (without parts points)
  ShapeLine    (WideLine points) -> ShapeLine . WideLine   <$> nonEmpty (without parts points)



modifyShapes :: (a -> Shape -> Maybe Shape) ->  Map AnnotationId a -> Editor ->  DocumentPatch
modifyShapes f m doc = PatchAnns $ M.intersectionWith f' m (doc ^. #annotations) where
  f' a annot  = case f a (annot ^. #shape) of
    Nothing    -> Delete
    Just shape -> Modify (annot & #shape .~ shape)


setClassEdit ::  ClassId -> Set AnnotationId -> Editor -> DocumentPatch
setClassEdit classId parts doc = PatchAnns $ M.intersectionWith f (setToMap' parts) (doc ^. #annotations) where
  f _ annot = Modify (annot & #label .~ classId)

deletePartsEdit ::   DocParts -> Editor -> DocumentPatch
deletePartsEdit = modifyShapes deleteParts


setAreaEdit :: Maybe Box -> Editor -> DocumentPatch
setAreaEdit b _ = PatchArea b


transformPartsEdit ::  Rigid -> DocParts -> Editor ->  DocumentPatch
transformPartsEdit  rigid = modifyShapes (\parts -> Just . transformParts rigid parts)

transformEdit ::  Rigid -> Set AnnotationId -> Editor ->  DocumentPatch
transformEdit  rigid ids  = modifyShapes (const $ Just . transformShape rigid) (setToMap' ids)

clearAllEdit :: Editor -> DocumentPatch
clearAllEdit doc = PatchAnns $ const Delete <$> doc ^. #annotations


detectionEdit :: [Detection] -> Editor -> DocumentPatch
detectionEdit detections doc = replace (fromDetections (nextId doc) detections) doc


replace :: AnnotationMap -> Editor -> DocumentPatch
replace anns  Editor{annotations}  = PatchAnns $ changes <$> align annotations anns where
  changes (These _ ann) = Modify ann
  changes (This _)   = Delete
  changes (That ann) = Add ann


confirmDetectionEdit :: Set AnnotationId -> Editor -> DocumentPatch
confirmDetectionEdit ids doc = PatchAnns $ M.intersectionWith f (setToMap' ids) (doc ^. #annotations) where
  f = const (Modify . confirmDetection)

confirmDetection :: Annotation -> Annotation
confirmDetection = #detection . traverse . _1 .~ Confirmed


addEdit :: [BasicAnnotation] -> Editor ->  DocumentPatch
addEdit anns doc = PatchAnns $ Add <$> anns' where
  anns' = M.fromList (zip [nextId doc..] $ fromBasic <$> anns)

patchMap :: (Ord k) =>  Map k (Maybe a) -> Map k a -> Map k a
patchMap patch m = m `diff` patch <> M.mapMaybe id adds where
  adds = patch `M.difference` m
  diff = M.differenceWith (flip const)

editPatch :: Edit -> Editor -> DocumentPatch
editPatch = \case
  EditSetClass i ids          -> setClassEdit i ids
  EditDeleteParts parts       -> deletePartsEdit parts
  EditTransformParts t parts  -> transformPartsEdit t parts
  EditClearAll                -> clearAllEdit
  EditDetection detections    -> detectionEdit detections
  EditAdd anns                -> addEdit anns
  EditSetArea area            -> setAreaEdit area
  EditConfirmDetection ids    -> confirmDetectionEdit ids

patchInverse :: Editor -> DocumentPatch -> Maybe (DocumentPatch, DocumentPatch')
patchInverse doc (PatchAnns e) = do
  undoPatch  <- itraverse (patchAnnotations (doc ^. #annotations)) e
  return (PatchAnns (fst <$> undoPatch), PatchAnns' $ snd <$> undoPatch)

patchInverse doc (PatchArea b) =
  return (PatchArea (doc ^. #validArea), PatchArea' b)


patchAnnotations :: AnnotationMap -> AnnotationId -> AnnotationPatch ->  Maybe (AnnotationPatch, Maybe Annotation)
patchAnnotations anns k action  =  case action of
  Add ann   -> return (Delete, Just ann)
  Delete    -> do
    ann <- M.lookup k anns
    return (Add ann, Nothing)
  Modify ann -> do
    ann' <- M.lookup k anns
    return (Modify ann', Just ann)