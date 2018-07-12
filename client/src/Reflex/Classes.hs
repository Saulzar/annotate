module Reflex.Classes
  ( module Reflex.Classes
  , module Reflex.Dom
  , module Reflex.Active
  , (<!>)
  ) where

import Annotate.Common

import qualified Reflex as R
import Reflex.Dom hiding (switchHold, switch, (=:), sample, Builder, link, Delete, Key(..))
import Reflex.Active

import Data.Functor
import Data.Functor.Compose
import Data.Functor.Alt ((<!>))
import Data.String

import qualified Data.Map as M
import qualified Data.Set as S
import Data.Functor.Misc

import Annotate.Geometry

import Control.Lens (Getting, _Left, _Right)
import Control.Applicative

import Data.Sequence ( ViewL(..), Seq(..), viewl, (|>) )
import qualified Data.Sequence as Seq

import Data.Dependent.Sum
import Data.GADT.Compare


data Updated t a = Updated a (Event t a)
data Patched t p = Patched (PatchTarget p) (Event t p)

changes ::  Reflex t => Dynamic t a -> (a -> a -> b) -> Event t b
changes d f = attachWith f (current d) (updated d)

maybeChanges ::  Reflex t => Dynamic t a -> (a -> a -> Maybe b) -> Event t b
maybeChanges d f = attachWithMaybe f (current d) (updated d)



instance Reflex t => Functor (Updated t) where
  fmap f (Updated initial e) = Updated (f initial) (f <$> e)

runWithReplace' :: Adjustable t m => Event t (m b) -> m (Event t b)
runWithReplace' e = snd <$> runWithReplace blank e

replaceHold :: (Adjustable t m, SwitchHold t a, MonadHold t m) => m a -> Event t (m a) -> m a
replaceHold initial e = uncurry switchHold =<< runWithReplace initial e

runWithClose :: (Adjustable t m, MonadHold t m, MonadFix m) => Event t (m (Event t a)) -> m (Event t a)
runWithClose e = do
  rec result <- replaceHold closed (leftmost [e, closed <$ result])
  return result
    where closed = return never

holdQueue :: (MonadHold t m, MonadFix m, Reflex t) => Event t [a] -> Dynamic t Bool -> m (Event t a)
holdQueue input occupied = mdo
  queue  <- fmap current $ holdDyn mempty $
    leftmost [remaining, enqueue]

  let (next, remaining) = split $ peek <?> (queue <@ free)
      free = ffilter not (updated occupied)

      (now, later) = split $ attachWith route (current occupied) input
      enqueue = attachWith (\q l -> q `mappend` Seq.fromList l) queue (filterMaybe later)

  return $ leftmost [filterMaybe now, next]

  where
    route False (x:xs) = (Just x, Just xs)
    route True xs      = (Nothing, Just xs)
    route _ _          = (Nothing, Nothing)

    peek q = case viewl q of
         (a :< rest) -> Just (a, rest)
         EmptyL -> Nothing

runWithQueue :: (Adjustable t m, MonadHold t m, MonadFix m) => Event t (m a) -> m (Event t a)
runWithQueue e = mdo
  result <- runWithReplace' $
    leftmost [fmap Just <$> e', return Nothing <$ result]

  open <- holdDyn False (isJust <$> result)
  e' <- holdQueue (pure <$> e) open

  return (filterMaybe result)


replaceFor ::(Adjustable t m, SwitchHold t b, MonadHold t m) => a -> Event t a -> (a -> m b) -> m b
replaceFor initial e f = replaceHold (f initial) (f <$> e)

split :: Functor f => f (a, b) -> (f a, f b)
split ab = (fst <$> ab, snd <$> ab)


splitEither :: Reflex t => Event t (Either a b) -> (Event t a, Event t b)
splitEither e = (preview _Left <?> e, preview _Right <?> e)

class Reflex t => Switch t f where
  switch :: f (Event t a) -> Event t a

instance Reflex t => Switch t (Behavior t) where
  switch = R.switch

instance Reflex t => Switch t (Dynamic t) where
  switch = switch . current


class Reflex t => SwitchPrompt t f where
  switchPrompt :: f (Event t a) -> Event t a

instance Reflex t => SwitchPrompt t (Event t) where
  switchPrompt = R.coincidence

instance Reflex t => SwitchPrompt t (Dynamic t) where
  switchPrompt = switchPromptlyDyn



class Reflex t => SwitchHold t a where
  switchHold :: MonadHold t m => a -> Event t a -> m a

instance Reflex t => SwitchHold t (Event t a) where
  switchHold e ee = switch <$> hold e ee

instance Reflex t => SwitchHold t (Behavior t a) where
  switchHold = R.switcher

instance Reflex t => SwitchHold t () where
    switchHold _ _ = return ()

instance (Reflex t, SwitchHold t a, SwitchHold t b) => SwitchHold t (a, b) where
    switchHold (a, b) e = liftA2 (,)
      (switchHold a (fst <$> e))
      (switchHold b (snd <$> e))


instance Reflex t => SwitchHold t (Dynamic t a) where
  switchHold d ed = do

    let eb = current <$> ed

    b <- switchHold (current d) eb
    e <- switchHold (updated d) (updated <$> ed)
    buildDynamic (sample b) (pushAlways sample eb <!> e)



class Reflex t => Sample t f where
    sample :: MonadSample t m => f t a -> m a


instance Reflex t => Sample t Behavior where
  sample = R.sample

instance Reflex t => Sample t Dynamic where
  sample = R.sample . current


(<#>) :: Reflex t => Event t (a -> b) -> Behavior t a -> Event t b
(<#>) e b = attachWith (\a f -> f a) b e

filterMaybe :: FunctorMaybe f => f (Maybe a) -> f a
filterMaybe = fmapMaybe id


(<?>) :: FunctorMaybe f => (a -> Maybe b) -> f a -> f b
(<?>) = fmapMaybe

(?>) :: FunctorMaybe f => Getting (First a) s a -> f s -> f a
(?>) getter f = preview getter <?> f

infixl 4 ?>
infixl 4 <?>
infixl 4 <#>

instance (Reflex t, Num a) => Num (Dynamic t a) where
  (+) = liftA2 (+)
  (-) = liftA2 (-)
  (*) = liftA2 (*)
  negate  = fmap negate
  abs     = fmap abs
  signum  = fmap signum
  fromInteger = pure . fromInteger



gated :: (Functor f, Monoid a) => a -> f Bool -> f a
gated a d = ffor d $ \cond -> if cond then a else mempty

swapping :: (Functor f) => (a, a) -> f Bool -> f a
swapping (a, b) d = ffor d $ \cond -> if cond then a else b


partition :: Reflex t => Behavior t Bool -> Event t a -> (Event t a, Event t a)
partition b e = (gate b e, gate (not <$> b) e)


postValue :: PostBuild t m => a -> m (Event t a)
postValue a = fmap (const a) <$> getPostBuild

postCurrent :: PostBuild t m => Behavior t a -> m (Event t a)
postCurrent b = tag b <$> getPostBuild

-- Collections
traverseMapWithAdjust :: forall t m k v a. (Ord k, Adjustable t m, MonadHold t m)
                      => Map k v -> Event t (PatchMap k v) -> (k -> v -> m a) -> m (Map k a, Event t (PatchMap k a))
traverseMapWithAdjust m0 m' f = sequenceMapWithAdjust
      (M.mapWithKey f m0)
      (mapPatchMapWithKey f <$> m')


mapPatchMapWithKey :: (k -> a -> b) -> PatchMap k a -> PatchMap k b
mapPatchMapWithKey f = PatchMap . M.mapWithKey (\k v -> f k <$> v) . unPatchMap

traversePatchedMapWithAdjust :: (Ord k, Adjustable t m, MonadHold t m)
                      => Patched t (PatchMap k v) -> (k -> v -> m a) -> m (Patched t (PatchMap k a))
traversePatchedMapWithAdjust (Patched m0 m') = fmap (uncurry Patched) . traverseMapWithAdjust m0 m'



sequenceMapWithAdjust :: (Adjustable t m, Ord k)
                      => Map k (m a) -> Event t (PatchMap k (m a)) -> m (Map k a, Event t (PatchMap k a))
sequenceMapWithAdjust m0 m' = do
   (a0, a') <- sequenceDMapWithAdjust (mapWithFunctorToDMap m0) (patchMapDMap <$> m')
   return (dmapToMap a0, patchDMapMap <$> a')

patchMapDMap :: PatchMap k (f v) -> PatchDMap (Const2 k v) f
patchMapDMap = PatchDMap . mapWithFunctorToDMap . fmap ComposeMaybe . unPatchMap

patchDMapMap :: PatchDMap (Const2 k v) Identity -> PatchMap k v
patchDMapMap = PatchMap . dmapToMapWith (fmap runIdentity . getComposeMaybe) . unPatchDMap


holdMergePatched ::  (Ord k, Adjustable t m, MonadHold t m)
                 => Patched t (PatchMap k (Event t a)) -> m (Event t (Map k a))
holdMergePatched (Patched m0 m') = fmap dmapToMap . mergeIncremental <$>
     holdIncremental (mapWithFunctorToDMap m0) (patchMapDMap <$> m')



mapUpdates :: (Reflex t, MonadFix m, MonadHold t m, Ord k)
           => Map k v -> Event t (Map k (Maybe v)) -> m (Event t (Map k (Maybe v)))
mapUpdates a0 a' = do
  keys <- foldDyn applyMap (void a0) (fmap void <$> a')
  return (attachWith modifiedKeys (current keys) a')
    where
      modifiedKeys = flip (M.differenceWith relevantPatch)
      relevantPatch patch _ = case patch of
        Nothing -> Just Nothing   -- Item deleted
        Just _  -> Nothing        -- Item updated

keyUpdates :: (Reflex t, Ord k) => Event t (Map k (Maybe v)) -> (k -> Event t v)
keyUpdates e = select valueChanged . Const2 where
  valueChanged = fanMap $ M.mapMaybe id <$> e

traverseMapWithUpdates :: (Ord k, Adjustable t m, MonadFix m, MonadHold t m)
            => Map k v -> Event t (Map k (Maybe v)) -> (k -> v -> Event t v -> m a) -> m (Map k a, Event t (Map k (Maybe a)))
traverseMapWithUpdates v0 v' f = do
  keysChanged <- mapUpdates v0 v'
  (a0, a') <- traverseMapWithAdjust v0 (PatchMap <$> keysChanged) (\k v -> f k v (valueChanged k))
  return (a0, unPatchMap <$> a')
    where valueChanged = keyUpdates v'

patchMapWithUpdates :: (Ord k, Adjustable t m, MonadFix m, MonadHold t m)
                    => Patched t (PatchMap k v) -> (k -> Updated t v -> m a) -> m (Patched t (PatchMap k a))
patchMapWithUpdates (Patched m0 m') f = do
  keysChanged <- mapUpdates m0 updates
  traversePatchedMapWithAdjust (Patched m0 (PatchMap <$> keysChanged)) (\k v -> f k (Updated v (valueChanged k)))
    where
      valueChanged = keyUpdates updates
      updates = unPatchMap <$> m'



-- Workflow related
mapTransition ::  (MonadHold t m, Reflex t) => (Event t (Workflow t m a) -> Event t (Workflow t m a)) -> Workflow t m a -> Workflow t m a
mapTransition f = mapTransitionOnce (fmap (mapTransition f) . f)


mapTransitionOnce ::  (MonadHold t m, Reflex t) => (Event t (Workflow t m a) -> Event t (Workflow t m a)) -> Workflow t m a -> Workflow t m a
mapTransitionOnce f (Workflow m) = Workflow (over _2 f <$> m)

commonTransition :: (MonadHold t m, Reflex t) => Event t (Workflow t m a) -> Workflow t m a -> Workflow t m a
commonTransition e w = mapTransition (e <!>) w


holdWorkflow :: forall t m a. (Reflex t, Adjustable t m, MonadFix m, MonadHold t m, SwitchHold t a) => Workflow t m a -> m a
holdWorkflow w0 = do
 rec (r, transition) <- replaceHold (unWorkflow w0) $ (unWorkflow <$> transition)
 return r

workflow' :: (Reflex t, MonadHold t m) => m (Event t (Workflow t m ())) -> Workflow t m ()
workflow' m = Workflow $ ((),) <$> m


-- Factorisation for Dynamics

-- valueUpdates :: GEq k => k a -> DSum k f -> Maybe (f a)
-- valueUpdates k (k' :=> v) = case geq k k' of
--   Just Refl -> Just v 
--   Nothing   -> Nothing
-- 
-- keyChanges :: GEq k => DSum k f -> DSum k f -> Maybe (DSum k f)
-- keyChanges (k :=> _) (k' :=> v') = case geq k k' of
--   Just Refl -> Nothing
--   Nothing   -> Just (k' :=> v')
-- 
-- factorDyn' :: forall t k f. (Reflex t, GEq k) 
--            => Dynamic t (DSum k f) -> Dynamic t (DSum k (Compose (Dynamic t) f))
-- factorDyn' d = inner <$> unsafeBuildDynamic initial updates where
-- 
--   initial = sample (current d)
--   updates = maybeChanges d keyChanges
-- 
--   inner :: DSum k f -> DSum k (Compose (Dynamic t) f) 
--   inner (k :=> v) = k :=> Compose (holdDyn v (valueUpdates k <?> updated d))
-- 
  



-- Fan for Dynamics
fanWith :: (Reflex t, Ord k) => (k -> a -> b) -> (a -> a -> Map k b) -> Dynamic t a -> (k -> Dynamic t b)
fanWith fromCurrent diffChanges d = \k -> unsafeBuildDynamic (fromCurrent k <$> sample (current d)) (select s (Const2 k))
  where s = fanMap $ changes d diffChanges
 

fanDynMap :: (Reflex t, Ord k, Eq a) => Dynamic t (Map k a)  -> (k -> Dynamic t (Maybe a))
fanDynMap = fanWith M.lookup diffMap

fanDynSet :: (Reflex t, Ord k) => Dynamic t (Set k) -> (k -> Dynamic t Bool)
fanDynSet = fanWith S.member diffSets

diffSets :: Ord k => Set k -> Set k -> Map k Bool
diffSets old new = setToMap True added <> setToMap False deleted
  where added   = S.difference new old
        deleted = S.difference old new
        
setToMap :: Ord k =>  a ->  Set k -> Map k a
setToMap a = M.fromDistinctAscList . fmap (, a) . S.toAscList        
  
fanDyn :: (Reflex t, Ord k) => Dynamic t k -> (k -> Dynamic t Bool)
fanDyn = fanWith (==) diffEq

diffEq :: Ord k => k -> k -> Map k Bool
diffEq k k' 
  | k == k'     = mempty
  | otherwise   = M.fromList [(k, False), (k', True)]





  
  