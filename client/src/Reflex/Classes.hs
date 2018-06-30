module Reflex.Classes
  ( module Reflex.Classes
  , module Reflex.Dom
  , module Reflex.Active
  , (<!>)
  ) where

import Annotate.Common

import qualified Reflex as R
import Reflex.Dom hiding (switchHold, switch, (=:), sample, Builder, link)
import Reflex.Active

import Data.Functor
import Data.Functor.Alt ((<!>))
import Data.String

import qualified Data.Map as M
import qualified Data.Set as S
import Data.Functor.Misc

import Annotate.Geometry

import Control.Lens (Getting)
import Control.Applicative




data Updated t a = Updated a (Event t a)
data Patched t p = Patched (PatchTarget p) (Event t p)

observeChanges ::  Reflex t => Dynamic t a -> (a -> a -> b) -> Event t b
observeChanges d f = attachWith f (current d) (updated d)


instance Reflex t => Functor (Updated t) where
  fmap f (Updated initial e) = Updated (f initial) (f <$> e)

runWithReplace' :: Adjustable t m => Event t (m b) -> m (Event t b)
runWithReplace' e = snd <$> runWithReplace blank e

replaceHold :: (Adjustable t m, SwitchHold t a, MonadHold t m) => m a -> Event t (m a) -> m a
replaceHold initial e = uncurry switchHold =<< runWithReplace initial e

replaceFor ::(Adjustable t m, SwitchHold t b, MonadHold t m) => a -> Event t a -> (a -> m b) -> m b
replaceFor initial e f = replaceHold (f initial) (f <$> e)

split :: Functor f => f (a, b) -> (f a, f b)
split ab = (fst <$> ab, snd <$> ab)


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




gated :: Reflex t => Monoid a => a -> Dynamic t Bool -> Dynamic t a
gated a d = ffor d $ \cond -> if cond then a else mempty



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
mapTransition f = mapTransition' (fmap (mapTransition f) . f)


mapTransition' ::  (MonadHold t m, Reflex t) => (Event t (Workflow t m a) -> Event t (Workflow t m a)) -> Workflow t m a -> Workflow t m a
mapTransition' f (Workflow m) = Workflow (over _2 f <$> m)

commonTransition :: (MonadHold t m, Reflex t) => Event t (Workflow t m a) -> Workflow t m a -> Workflow t m a
commonTransition e w = mapTransition (e <!>) w


holdWorkflow :: forall t m a. (Reflex t, Adjustable t m, MonadFix m, MonadHold t m, SwitchHold t a) => Workflow t m a -> m a
holdWorkflow w0 = do
 rec (r, transition) <- replaceHold (unWorkflow w0) $ (unWorkflow <$> transition)
 return r

workflow' :: (Reflex t, MonadHold t m) => m (Event t (Workflow t m ())) -> Workflow t m ()
workflow' m = Workflow $ ((),) <$> m



-- Fan for 'Dynamic' types
fanDynMap :: (Reflex t, Ord k, Eq a) => Dynamic t (Map k a)  -> (k -> Dynamic t (Maybe a))
fanDynMap d = \k -> unsafeBuildDynamic (M.lookup k <$> sample (current d)) (select s (Const2 k))
    where s = fanMap $ observeChanges d diffMap

toMap :: Ord k =>  a ->  Set k -> Map k a
toMap a = M.fromDistinctAscList . fmap (, a) . S.toAscList

diffSets :: Ord k => Set k -> Set k -> Map k Bool
diffSets old new = toMap True added <> toMap False deleted
  where added   = S.difference new old
        deleted = S.difference old new

fanDynSet :: (Reflex t, Ord k) => Dynamic t (Set k)  -> (k -> Dynamic t Bool)
fanDynSet d = \k -> unsafeBuildDynamic (S.member k <$> sample (current d)) (select s (Const2 k))
  where s = fanMap $ observeChanges d diffSets
