-- | UI of inventory management.
module Game.LambdaHack.Client.UI.InventoryM
  ( Suitability(..)
  , getFull, getGroupItem, getStoreItem
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import qualified Data.Char as Char
import           Data.Either
import qualified Data.EnumMap.Strict as EM
import qualified Data.Text as T
import           Data.Tuple (swap)
import qualified NLP.Miniutter.English as MU

import           Game.LambdaHack.Client.MonadClient
import           Game.LambdaHack.Client.State
import           Game.LambdaHack.Client.UI.ActorUI
import           Game.LambdaHack.Client.UI.Content.Screen
import           Game.LambdaHack.Client.UI.ContentClientUI
import           Game.LambdaHack.Client.UI.Frame
import           Game.LambdaHack.Client.UI.HandleHelperM
import           Game.LambdaHack.Client.UI.HumanCmd
import           Game.LambdaHack.Client.UI.ItemSlot
import qualified Game.LambdaHack.Client.UI.Key as K
import           Game.LambdaHack.Client.UI.MonadClientUI
import           Game.LambdaHack.Client.UI.MsgM
import           Game.LambdaHack.Client.UI.SessionUI
import           Game.LambdaHack.Client.UI.Slideshow
import           Game.LambdaHack.Client.UI.SlideshowM
import           Game.LambdaHack.Common.Actor
import           Game.LambdaHack.Common.ActorState
import           Game.LambdaHack.Common.Faction
import           Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.ItemAspect as IA
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.MonadStateRead
import           Game.LambdaHack.Common.State
import           Game.LambdaHack.Common.Types
import qualified Game.LambdaHack.Definition.Ability as Ability
import           Game.LambdaHack.Definition.Defs

data ItemDialogState = ISuitable | IAll
  deriving (Show, Eq)

accessModeBag :: ActorId -> State -> ItemDialogMode -> ItemBag
accessModeBag leader s (MStore cstore) = let b = getActorBody leader s
                                         in getBodyStoreBag b cstore s
accessModeBag leader s MOrgans = let b = getActorBody leader s
                                 in getBodyStoreBag b COrgan s
accessModeBag leader s MOwned = let fid = bfid $ getActorBody leader s
                                in combinedItems fid s
accessModeBag _ _ MSkills = EM.empty
accessModeBag _ s MLore{} = EM.map (const (1, [])) $ sitemD s
accessModeBag _ _ MPlaces = EM.empty

-- | Let a human player choose any item from a given group.
-- Note that this does not guarantee the chosen item belongs to the group,
-- as the player can override the choice.
-- Used e.g., for applying and projecting.
getGroupItem :: MonadClientUI m
             => m Suitability
                          -- ^ which items to consider suitable
             -> Text      -- ^ specific prompt for only suitable items
             -> Text      -- ^ generic prompt
             -> [CStore]  -- ^ initial legal modes
             -> [CStore]  -- ^ legal modes after Calm taken into account
             -> m (Either Text (ItemId, (ItemDialogMode, Either K.KM SlotChar)))
getGroupItem psuit prompt promptGeneric
             cLegalRaw cLegalAfterCalm = do
  soc <- getFull psuit
                 (\_ _ _ cCur _ -> prompt <+> ppItemDialogModeFrom cCur)
                 (\_ _ _ cCur _ -> promptGeneric <+> ppItemDialogModeFrom cCur)
                 cLegalRaw cLegalAfterCalm True False
  case soc of
    Left err -> return $ Left err
    Right ([(iid, _)], cekm) -> return $ Right (iid, cekm)
    Right _ -> error $ "" `showFailure` soc

-- | Display all items from a store and let the human player choose any
-- or switch to any other store.
-- Used, e.g., for viewing inventory and item descriptions.
getStoreItem :: MonadClientUI m
             => (Actor -> ActorUI -> Ability.Skills -> ItemDialogMode -> State
                 -> Text)        -- ^ how to describe suitable items
             -> ItemDialogMode   -- ^ initial mode
             -> m ( Either Text (ItemId, ItemBag, SingleItemSlots)
                  , (ItemDialogMode, Either K.KM SlotChar) )
getStoreItem prompt cInitial = do
  let itemCs = map MStore [CStash, CEqp, CGround]
      loreCs = map MLore [minBound..maxBound] ++ [MPlaces]
      allCs = case cInitial of
        MLore{} -> loreCs
        MPlaces -> loreCs
        _ -> itemCs ++ [MOwned, MOrgans, MSkills]
      (pre, rest) = break (== cInitial) allCs
      post = dropWhile (== cInitial) rest
      remCs = post ++ pre
  soc <- getItem (return SuitsEverything)
                 prompt prompt cInitial remCs
                 True False (cInitial : remCs)
  case soc of
    (Left err, cekm) -> return (Left err, cekm)
    (Right ([iid], itemBag, lSlots), cekm) ->
      return (Right (iid, itemBag, lSlots), cekm)
    (Right{}, _) -> error $ "" `showFailure` soc

-- | Let the human player choose a single, preferably suitable,
-- item from a list of items. Don't display stores empty for all actors.
-- Start with a non-empty store.
getFull :: MonadClientUI m
        => m Suitability    -- ^ which items to consider suitable
        -> (Actor -> ActorUI -> Ability.Skills -> ItemDialogMode -> State
            -> Text)        -- ^ specific prompt for only suitable items
        -> (Actor -> ActorUI -> Ability.Skills -> ItemDialogMode -> State
            -> Text)        -- ^ generic prompt
        -> [CStore]         -- ^ initial legal modes
        -> [CStore]         -- ^ legal modes with Calm taken into account
        -> Bool             -- ^ whether to ask, when the only item
                            --   in the starting mode is suitable
        -> Bool             -- ^ whether to permit multiple items as a result
        -> m (Either Text ( [(ItemId, ItemQuant)]
                          , (ItemDialogMode, Either K.KM SlotChar) ))
getFull psuit prompt promptGeneric cLegalRaw cLegalAfterCalm
        askWhenLone permitMulitple = do
  side <- getsClient sside
  leader <- getLeaderUI
  let aidNotEmpty store aid = do
        body <- getsState $ getActorBody aid
        bag <- getsState $ getBodyStoreBag body store
        return $! not $ EM.null bag
      partyNotEmpty store = do
        as <- getsState $ fidActorNotProjGlobalAssocs side
        bs <- mapM (aidNotEmpty store . fst) as
        return $! or bs
  mpsuit <- psuit
  let psuitFun = case mpsuit of
        SuitsEverything -> \_ _ -> True
        SuitsSomething f -> f
  -- Move the first store that is non-empty for suitable items for this actor
  -- to the front, if any.
  b <- getsState $ getActorBody leader
  getCStoreBag <- getsState $ \s cstore -> getBodyStoreBag b cstore s
  let hasThisActor = not . EM.null . getCStoreBag
  case filter hasThisActor cLegalAfterCalm of
    [] -> case filter hasThisActor cLegalRaw of
            [] -> do
              let contLegalRaw = map MStore cLegalRaw
                  tLegal = map (MU.Text . ppItemDialogModeIn) contLegalRaw
                  ppLegal = makePhrase [MU.WWxW "nor" tLegal]
              return $ Left $ "no items" <+> ppLegal
            [CEqp] -> return $! Left "not calm enough to remove equipment"
            [CGround, CEqp] ->  -- order matters
              return $! Left "not calm enough to remove equipment"
            [CGround] -> return $! Left "you vainly paw through your own hoard"
            _ -> return $! Left "no relevant items"
    haveThis@(headThisActor : _) -> do
      itemToF <- getsState $ flip itemToFull
      let suitsThisActor store =
            let bag = getCStoreBag store
            in any (\(iid, kit) -> psuitFun (itemToF iid) kit) $ EM.assocs bag
          firstStore = fromMaybe headThisActor $ find suitsThisActor haveThis
      -- Don't display stores totally empty for all actors.
      cLegal <- filterM partyNotEmpty cLegalRaw
      let breakStores cInit =
            let (pre, rest) = break (== cInit) cLegal
                post = dropWhile (== cInit) rest
            in (MStore cInit, map MStore $ post ++ pre)
      let (modeFirst, modeRest) = breakStores firstStore
      res <- getItem psuit prompt promptGeneric modeFirst modeRest
                     askWhenLone permitMulitple (map MStore cLegal)
      case res of
        (Left t, _) -> return $ Left t
        (Right (iids, itemBag, _lSlots), cekm) -> do
          let f iid = (iid, itemBag EM.! iid)
          return $ Right (map f iids, cekm)

-- | Let the human player choose a single, preferably suitable,
-- item from a list of items.
getItem :: MonadClientUI m
        => m Suitability    -- ^ which items to consider suitable
        -> (Actor -> ActorUI -> Ability.Skills -> ItemDialogMode -> State
            -> Text)        -- ^ specific prompt for only suitable items
        -> (Actor -> ActorUI -> Ability.Skills -> ItemDialogMode -> State
            -> Text)        -- ^ generic prompt
        -> ItemDialogMode   -- ^ first mode, legal or not
        -> [ItemDialogMode] -- ^ the (rest of) legal modes
        -> Bool             -- ^ whether to ask, when the only item
                            --   in the starting mode is suitable
        -> Bool             -- ^ whether to permit multiple items as a result
        -> [ItemDialogMode] -- ^ all legal modes
        -> m ( Either Text ([ItemId], ItemBag, SingleItemSlots)
             , (ItemDialogMode, Either K.KM SlotChar) )
getItem psuit prompt promptGeneric cCur cRest askWhenLone permitMulitple
        cLegal = do
  leader <- getLeaderUI
  accessCBag <- getsState $ accessModeBag leader
  let storeAssocs = EM.assocs . accessCBag
      allAssocs = concatMap storeAssocs (cCur : cRest)
  case allAssocs of
    [(iid, k)] | null cRest && not askWhenLone -> do
      ItemSlots itemSlots <- getsSession sslots
      let lSlots = itemSlots EM.! IA.loreFromMode cCur
          slotChar = fromMaybe (error $ "" `showFailure` (iid, lSlots))
                     $ lookup iid $ map swap $ EM.assocs lSlots
      return ( Right ([iid], EM.singleton iid k, EM.singleton slotChar iid)
             , (cCur, Right slotChar) )
    _ ->
      transition psuit prompt promptGeneric permitMulitple cLegal
                 0 cCur cRest ISuitable

data DefItemKey m = DefItemKey
  { defLabel  :: Either Text K.KM
  , defCond   :: Bool
  , defAction :: Either K.KM SlotChar
              -> m ( Either Text ([ItemId], ItemBag, SingleItemSlots)
                   , (ItemDialogMode, Either K.KM SlotChar) )
  }

data Suitability =
    SuitsEverything
  | SuitsSomething (ItemFull -> ItemQuant -> Bool)

transition :: forall m. MonadClientUI m
           => m Suitability
           -> (Actor -> ActorUI -> Ability.Skills -> ItemDialogMode -> State
               -> Text)
           -> (Actor -> ActorUI -> Ability.Skills -> ItemDialogMode -> State
               -> Text)
           -> Bool
           -> [ItemDialogMode]
           -> Int
           -> ItemDialogMode
           -> [ItemDialogMode]
           -> ItemDialogState
           -> m ( Either Text ([ItemId], ItemBag, SingleItemSlots)
                , (ItemDialogMode, Either K.KM SlotChar) )
transition psuit prompt promptGeneric permitMulitple cLegal
           numPrefix cCur cRest itemDialogState = do
  let recCall = transition psuit prompt promptGeneric permitMulitple cLegal
  ItemSlots itemSlotsPre <- getsSession sslots
  leader <- getLeaderUI
  body <- getsState $ getActorBody leader
  bodyUI <- getsSession $ getActorUI leader
  actorMaxSk <- getsState $ getActorMaxSkills leader
  fact <- getsState $ (EM.! bfid body) . sfactionD
  hs <- partyAfterLeader leader
  bagAll <- getsState $ \s -> accessModeBag leader s cCur
  itemToF <- getsState $ flip itemToFull
  revCmd <- revCmdMap
  mpsuit <- psuit  -- when throwing, this sets eps and checks xhair validity
  psuitFun <- case mpsuit of
    SuitsEverything -> return $ \_ _ -> True
    SuitsSomething f -> return f  -- When throwing, this function takes
                                  -- missile range into accout.
  -- This is the only place slots are sorted. As a side-effect,
  -- slots in inventories always agree with slots of item lore.
  -- Not so for organ menu, because many lore maps point there.
  -- Sorting in @updateItemSlot@ would not be enough, because, e.g.,
  -- identifying an item should change its slot position.
  lSlots <- case cCur of
    MOrgans -> do
      let newSlots = EM.adjust (sortSlotMap itemToF) SOrgan
                     $ EM.adjust (sortSlotMap itemToF) STrunk
                     $ EM.adjust (sortSlotMap itemToF) SCondition itemSlotsPre
      modifySession $ \sess -> sess {sslots = ItemSlots newSlots}
      return $! mergeItemSlots itemToF [ newSlots EM.! SOrgan
                                       , newSlots EM.! STrunk
                                       , newSlots EM.! SCondition ]
    MSkills -> return EM.empty
    MPlaces -> return EM.empty
    _ -> do
      let slore = IA.loreFromMode cCur
          newSlots = EM.adjust (sortSlotMap itemToF) slore itemSlotsPre
      modifySession $ \sess -> sess {sslots = ItemSlots newSlots}
      return $! newSlots EM.! slore
  let getResult :: Either K.KM SlotChar -> [ItemId]
                -> ( Either Text ([ItemId], ItemBag, SingleItemSlots)
                   , (ItemDialogMode, Either K.KM SlotChar) )
      getResult ekm iids = (Right (iids, bagAll, bagItemSlotsAll), (cCur, ekm))
      filterP iid = psuitFun (itemToF iid)
      bagAllSuit = EM.filterWithKey filterP bagAll
      bagItemSlotsAll = EM.filter (`EM.member` bagAll) lSlots
      -- Predicate for slot matching the current prefix, unless the prefix
      -- is 0, in which case we display all slots, even if they require
      -- the user to start with number keys to get to them.
      -- Could be generalized to 1 if prefix 1x exists, etc., but too rare.
      hasPrefixOpen x _ = slotPrefix x == numPrefix || numPrefix == 0
      bagItemSlotsOpen = EM.filterWithKey hasPrefixOpen bagItemSlotsAll
      hasPrefix x _ = slotPrefix x == numPrefix
      bagItemSlots = EM.filterWithKey hasPrefix bagItemSlotsOpen
      bag = EM.fromList $ map (\iid -> (iid, bagAll EM.! iid))
                              (EM.elems bagItemSlotsOpen)
      suitableItemSlotsAll = EM.filter (`EM.member` bagAllSuit) lSlots
      suitableItemSlotsOpen =
        EM.filterWithKey hasPrefixOpen suitableItemSlotsAll
      bagSuit = EM.fromList $ map (\iid -> (iid, bagAllSuit EM.! iid))
                                  (EM.elems suitableItemSlotsOpen)
      nextContainers forward = do
        mstash <- getsState $ \s -> gstash $ sfactionD s EM.! bfid body
        let overStash = mstash == Just (blid body, bpos body)
            calmE = calmEnough body actorMaxSk
            mcCur = filter (`elem` cLegal) [cCur]
            (cCurAfterCalm, cRestAfterCalm) =
              if forward
              then case cRest ++ mcCur of
                c1@(MStore CEqp) : c2@(MStore CGround) : c3 : rest
                  | not calmE && overStash ->
                    (c3, c1 : c2 : rest)
                c1@(MStore CGround) : c2@(MStore CEqp) : c3 : rest
                  | not calmE && overStash ->
                    (c3, c1 : c2 : rest)
                c1@(MStore CEqp) : c2 : rest | not calmE ->
                  (c2, c1 : rest)
                c1@(MStore CGround) : c2 : rest | overStash ->
                  (c2, c1 : rest)
                c1 : rest -> (c1, rest)
                [] -> error $ "" `showFailure` cRest
              else case reverse $ mcCur ++ cRest of
                c1@(MStore CEqp) : c2@(MStore CGround) : c3 : rest
                  | not calmE && overStash ->
                    (c3, reverse $ c1 : c2 : rest)
                c1@(MStore CGround) : c2@(MStore CEqp) : c3 : rest
                  | not calmE && overStash ->
                    (c3, reverse $ c1 : c2 : rest)
                c1@(MStore CEqp) : c2 : rest | not calmE ->
                  (c2, reverse $ c1 : rest)
                c1@(MStore CGround) : c2 : rest | overStash ->
                  (c2, reverse $ c1 : rest)
                c1 : rest -> (c1, reverse rest)
                [] -> error $ "" `showFailure` cRest
        return (cCurAfterCalm, cRestAfterCalm)
  nextContainersForward <- nextContainers True
  nextContainersBackward <- nextContainers False
  (bagFiltered, promptChosen) <- getsState $ \s ->
    case itemDialogState of
      ISuitable -> (bagSuit, prompt body bodyUI actorMaxSk cCur s <> ":")
      IAll      -> (bag, promptGeneric body bodyUI actorMaxSk cCur s <> ":")
  let (autoDun, _) = autoDungeonLevel fact
      multipleSlots = if itemDialogState == IAll
                      then bagItemSlotsAll
                      else suitableItemSlotsAll
      maySwitchLeader MOwned = False
      maySwitchLeader MLore{} = False
      maySwitchLeader MPlaces = False
      maySwitchLeader _ = True
      keyDefs :: [(K.KM, DefItemKey m)]
      keyDefs = filter (defCond . snd) $
        [ let km = K.mkChar '<'
          in (km, changeContainerDef False $ Right km)
        , let km = K.mkChar '>'
          in (km, changeContainerDef True $ Right km)
        , let km = K.mkChar '+'
          in (km, DefItemKey
           { defLabel = Right km
           , defCond = bag /= bagSuit
           , defAction = \_ -> recCall numPrefix cCur cRest
                               $ case itemDialogState of
                                   ISuitable -> IAll
                                   IAll -> ISuitable
           })
        , let km = K.mkChar '*'
          in (km, useMultipleDef $ Right km)
        , let km = revCmd (K.KM K.NoModifier K.Tab) MemberCycle
          in (km, DefItemKey
           { defLabel = Right km
           , defCond = maySwitchLeader cCur
                       && any (\(_, b, _) -> blid b == blid body) hs
           , defAction = \_ -> do
               err <- memberCycle False
               let !_A = assert (isNothing err `blame` err) ()
               (cCurUpd, cRestUpd) <- legalWithUpdatedLeader cCur cRest
               recCall numPrefix cCurUpd cRestUpd itemDialogState
           })
        , let km = revCmd (K.KM K.NoModifier K.BackTab) MemberBack
          in (km, DefItemKey
           { defLabel = Right km
           , defCond = maySwitchLeader cCur && not (autoDun || null hs)
           , defAction = \_ -> do
               err <- memberBack False
               let !_A = assert (isNothing err `blame` err) ()
               (cCurUpd, cRestUpd) <- legalWithUpdatedLeader cCur cRest
               recCall numPrefix cCurUpd cRestUpd itemDialogState
           })
        , (K.KM K.NoModifier K.LeftButtonRelease, DefItemKey
           { defLabel = Left ""
           , defCond = maySwitchLeader cCur && not (null hs)
           , defAction = \ekm -> do
               merror <- pickLeaderWithPointer
               case merror of
                 Nothing -> do
                   (cCurUpd, cRestUpd) <- legalWithUpdatedLeader cCur cRest
                   recCall numPrefix cCurUpd cRestUpd itemDialogState
                 Just{} -> return ( Left "not a menu item nor teammate position"
                                  , (cCur, ekm) )
                             -- don't inspect the error, it's expected
           })
        , (K.escKM, DefItemKey
           { defLabel = Right K.escKM
           , defCond = True
           , defAction = \ekm -> return (Left "never mind", (cCur, ekm))
           })
        ]
        ++ numberPrefixes
      changeContainerDef forward defLabel =
        let (cCurAfterCalm, cRestAfterCalm) =
              if forward then nextContainersForward else nextContainersBackward
        in DefItemKey
          { defLabel
          , defCond = cCurAfterCalm /= cCur
          , defAction = \_ ->
              recCall numPrefix cCurAfterCalm cRestAfterCalm itemDialogState
          }
      useMultipleDef defLabel = DefItemKey
        { defLabel
        , defCond = permitMulitple && not (EM.null multipleSlots)
        , defAction = \ekm ->
            let eslots = EM.elems multipleSlots
            in return $ getResult ekm eslots
        }
      prefixCmdDef d =
        (K.mkChar $ Char.intToDigit d, DefItemKey
           { defLabel = Left ""
           , defCond = True
           , defAction = \_ ->
               recCall (10 * numPrefix + d) cCur cRest itemDialogState
           })
      numberPrefixes = map prefixCmdDef [0..9]
      lettersDef :: DefItemKey m
      lettersDef = DefItemKey
        { defLabel = Left ""
        , defCond = True
        , defAction = \ekm ->
            let slot = case ekm of
                  Left K.KM{key=K.Char l} -> SlotChar numPrefix l
                  Left km ->
                    error $ "unexpected key:" `showFailure` K.showKM km
                  Right sl -> sl
            in case EM.lookup slot bagItemSlotsAll of
              Nothing -> error $ "unexpected slot"
                                 `showFailure` (slot, bagItemSlots)
              Just iid -> return $! getResult (Right slot) [iid]
        }
  case cCur of
    MSkills -> do
      io <- skillsOverlay leader
      let slotLabels = map fst $ snd io
          slotKeys = mapMaybe (keyOfEKM numPrefix) slotLabels
          skillsDef :: DefItemKey m
          skillsDef = DefItemKey
            { defLabel = Left ""
            , defCond = True
            , defAction = \ekm ->
                let slot = case ekm of
                      Left K.KM{key} -> case key of
                        K.Char l -> SlotChar numPrefix l
                        _ -> error $ "unexpected key:"
                                     `showFailure` K.showKey key
                      Right sl -> sl
                in return (Left "skills", (MSkills, Right slot))
            }
      runDefItemKey keyDefs skillsDef io slotKeys promptChosen cCur
    MPlaces -> do
      io <- placesOverlay
      let slotLabels = map fst $ snd io
          slotKeys = mapMaybe (keyOfEKM numPrefix) slotLabels
          placesDef :: DefItemKey m
          placesDef = DefItemKey
            { defLabel = Left ""
            , defCond = True
            , defAction = \ekm ->
                let slot = case ekm of
                      Left K.KM{key} -> case key of
                        K.Char l -> SlotChar numPrefix l
                        _ -> error $ "unexpected key:"
                                     `showFailure` K.showKey key
                      Right sl -> sl
                in return (Left "places", (MPlaces, Right slot))
            }
      runDefItemKey keyDefs placesDef io slotKeys promptChosen cCur
    _ -> do
      io <- itemOverlay lSlots (blid body) bagFiltered
      let slotKeys = mapMaybe (keyOfEKM numPrefix . Right)
                     $ EM.keys bagItemSlots
      runDefItemKey keyDefs lettersDef io slotKeys promptChosen cCur

keyOfEKM :: Int -> Either [K.KM] SlotChar -> Maybe K.KM
keyOfEKM _ (Left kms) = error $ "" `showFailure` kms
keyOfEKM numPrefix (Right SlotChar{..}) | slotPrefix == numPrefix =
  Just $ K.mkChar slotChar
keyOfEKM _ _ = Nothing

legalWithUpdatedLeader :: MonadClientUI m
                       => ItemDialogMode
                       -> [ItemDialogMode]
                       -> m (ItemDialogMode, [ItemDialogMode])
legalWithUpdatedLeader cCur cRest = do
  leader <- getLeaderUI
  let newLegal = cCur : cRest  -- not updated in any way yet
  b <- getsState $ getActorBody leader
  actorMaxSk <- getsState $ getActorMaxSkills leader
  mstash <- getsState $ \s -> gstash $ sfactionD s EM.! bfid b
  let overStash = mstash == Just (blid b, bpos b)
      calmE = calmEnough b actorMaxSk
      legalAfterCalm = case newLegal of
        c1@(MStore CEqp) : c2 : rest | not calmE -> (c2, c1 : rest)
        c1@(MStore CGround) : c2 : rest | overStash -> (c2, c1 : rest)
        c1 : rest -> (c1, rest)
        [] -> error $ "" `showFailure` (cCur, cRest)
  return legalAfterCalm

-- We don't create keys from slots in @okx@, so they have to be
-- exolicitly given in @slotKeys@.
runDefItemKey :: MonadClientUI m
              => [(K.KM, DefItemKey m)]
              -> DefItemKey m
              -> OKX
              -> [K.KM]
              -> Text
              -> ItemDialogMode
              -> m ( Either Text ([ItemId], ItemBag, SingleItemSlots)
                   , (ItemDialogMode, Either K.KM SlotChar) )
runDefItemKey keyDefs lettersDef okx slotKeys prompt cCur = do
  let itemKeys = slotKeys ++ map fst keyDefs
      wrapB s = "[" <> s <> "]"
      (keyLabelsRaw, keys) = partitionEithers $ map (defLabel . snd) keyDefs
      keyLabels = filter (not . T.null) keyLabelsRaw
      choice = T.intercalate " " $ map wrapB $ nub keyLabels
        -- switch to Data.Containers.ListUtils.nubOrd when we drop GHC 8.4.4
  promptAdd0 $ prompt <+> choice
  CCUI{coscreen=ScreenContent{rheight}} <- getsSession sccui
  ekm <- do
    okxs <- overlayToSlideshow (rheight - 2) keys okx
    displayChoiceScreen (show cCur) ColorFull False okxs itemKeys
  case ekm of
    Left km -> case km `lookup` keyDefs of
      Just keyDef -> defAction keyDef ekm
      Nothing -> defAction lettersDef ekm  -- pressed; with current prefix
    Right _slot -> defAction lettersDef ekm  -- selected; with the given prefix
