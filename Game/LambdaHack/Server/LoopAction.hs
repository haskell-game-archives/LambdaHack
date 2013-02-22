{-# LANGUAGE OverloadedStrings #-}
-- | The main loop of the server, processing human and computer player
-- moves turn by turn.
module Game.LambdaHack.Server.LoopAction (loopSer, cmdAtomicBroad) where

import Control.Arrow (second, (&&&))
import Control.Monad
import qualified Control.Monad.State as St
import Control.Monad.Writer.Strict (WriterT, execWriterT, runWriterT)
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.List
import Data.Maybe
import qualified Data.Ord as Ord
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Action
import Game.LambdaHack.Actor
import Game.LambdaHack.ActorState
import Game.LambdaHack.CmdAtomic
import Game.LambdaHack.CmdAtomicSem
import Game.LambdaHack.CmdCli
import Game.LambdaHack.CmdSer
import Game.LambdaHack.Content.ActorKind
import Game.LambdaHack.Content.FactionKind
import Game.LambdaHack.Faction
import qualified Game.LambdaHack.Feature as F
import Game.LambdaHack.Item
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Level
import Game.LambdaHack.Msg
import Game.LambdaHack.Perception
import Game.LambdaHack.Point
import Game.LambdaHack.Random
import Game.LambdaHack.Server.Action
import Game.LambdaHack.Server.Config
import qualified Game.LambdaHack.Server.DungeonGen as DungeonGen
import Game.LambdaHack.Server.EffectSem
import Game.LambdaHack.Server.Fov
import Game.LambdaHack.Server.State
import Game.LambdaHack.State
import qualified Game.LambdaHack.Tile as Tile
import Game.LambdaHack.Time
import Game.LambdaHack.Utils.Assert

-- | Start a clip (a part of a turn for which one or more frames
-- will be generated). Do whatever has to be done
-- every fixed number of time units, e.g., monster generation.
-- Run the leader and other actors moves. Eventually advance the time
-- and repeat.
loopSer :: forall m . (MonadAction m, MonadServerChan m)
        => (FactionId -> CmdSer -> m [Atomic])
        -> (FactionId -> ConnCli -> Bool -> IO ())
        -> Kind.COps
        -> m ()
loopSer cmdSerSem executorC cops = do
  -- Recover states.
  restored <- tryRestore cops
  -- TODO: use the _msg somehow
  case restored of
    Right _msg ->  -- Starting a new game.
      gameReset cops
    Left (gloRaw, ser, _msg) -> do  -- Running a restored game.
      putState $ updateCOps (const cops) gloRaw
      putServer ser
  -- Set up connections
  connServer
  -- Launch clients.
  launchClients executorC
  -- Send init messages.
  initPer
  pers <- getsServer sper
  defLoc <- getsState localFromGlobal
  quit <- getsServer squit
  if isJust quit then do -- game restored from a savefile
    funBroadcastCli (\fid -> ContinueSavedCli (pers EM.! fid))
  else do  -- game restarted
    -- TODO: factor out common parts from restartGame and restoreOrRestart
    funBroadcastCli
       (\fid -> CmdAtomicCli (RestartA fid (pers EM.! fid) defLoc))
    populateDungeon
    -- Save ASAP in case of crashes and disconnects.
    saveGameBkp
  modifyServer $ \ser1 -> ser1 {squit = Nothing}
  let cinT = let r = timeTurn `timeFit` timeClip
             in assert (r > 2) r
  -- Loop.
  let loop :: Int -> m ()
      loop clipN = do
        let h arena = do
              -- Regenerate HP and add monsters each turn, not each clip.
              when (clipN `mod` cinT == 0) $ generateMonster arena
              when (clipN `mod` cinT == 1) $ regenerateLevelHP arena
              when (clipN `mod` cinT == 2) checkEndGame
              handleActors cmdSerSem arena timeZero
              modifyState $ updateTime arena $ timeAdd timeClip
        let f fac = do
              case gleader fac of
                Nothing -> return Nothing
                Just leader -> do
                  b <- getsState $ getActorBody leader
                  return $ Just $ blid b
        faction <- getsState sfaction
        marenas <- mapM f $ EM.elems faction
        let arenas = ES.toList $ ES.fromList $ catMaybes marenas
        mapM_ h arenas
        endOrLoop (loop (clipN + 1))
  loop 1

initPer :: MonadServer m => m ()
initPer = do
  cops <- getsState scops
  glo <- getState
  ser <- getServer
  config <- getsServer sconfig
  let tryFov = stryFov $ sdebugSer ser
      fovMode = fromMaybe (configFovMode config) tryFov
      pers = dungeonPerception cops fovMode glo
  modifyServer $ \ser1 -> ser1 {sper = pers}

atomicSem :: MonadAction m => Atomic -> m ()
atomicSem atomic = case atomic of
  Left cmd -> cmdAtomicSem cmd
  Right _ -> return ()

cmdAtomicBroad :: (MonadAction m, MonadServerChan m) => Atomic -> m ()
cmdAtomicBroad atomic = do
  -- Gather data from the old state.
  sOld <- getState
  persOld <- getsServer sper
  (ps, resets, atomicBroken, psBroken) <-
    case atomic of
      Left cmd -> do
        ps <- posCmdAtomic cmd
        resets <- resetsFovAtomic cmd
        atomicBroken <- breakCmdAtomic cmd
        psBroken <- mapM posCmdAtomic atomicBroken
        return (ps, resets, atomicBroken, psBroken)
      Right desc -> do
        ps <- posDescAtomic desc
        return (ps, Just [], [], [])
  let atomicPsBroken = zip atomicBroken psBroken
  -- TODO: assert also that the sum of psBroken is equal to ps
  -- TODO: with deep equality these assertions can be expensive. Optimize.
  assert (either (const $ resets == Just []
                          && (null atomicBroken
                             || fmap Left atomicBroken == [atomic]))
                 (const True) ps) $ return ()
  -- Perform the action on the server.
  atomicSem atomic
  -- Send some actions to the clients, one faction at a time.
  let sendA fid cmd = do
        sendUpdateUI fid $ CmdAtomicUI cmd
        sendUpdateCliAI fid $ CmdAtomicCli cmd
      sendUpdate fid (Left cmd) = sendA fid cmd
      sendUpdate fid (Right desc) = sendUpdateUI fid $ DescAtomicUI desc
      vis per = all (`ES.member` totalVisible per) . snd
      isOurs fid = either id (== fid)
      breakSend fid perNew = do
        let send2 (atomic2, ps2) = do
              let seen2 = either (isOurs fid) (vis perNew) ps2
              if seen2
                then sendUpdate fid $ Left atomic2
                else do
                  loud <- loudCmdAtomic atomic2
                  when loud $ sendUpdate fid
                            $ Right $ BroadcastD "You hear some noises."
        mapM_ send2 atomicPsBroken
      anySend fid perOld perNew = do
        let startSeen = either (isOurs fid) (vis perOld) ps
            endSeen = either (isOurs fid) (vis perNew) ps
        if startSeen && endSeen
          then sendUpdate fid atomic
          else breakSend fid perNew
      send fid = case ps of
        Right (arena, _) -> do
          let perOld = persOld EM.! fid EM.! arena
              resetsFid = maybe True (fid `elem`) resets
          if resetsFid then do
            resetFidPerception fid arena
            perNew <- getPerFid fid arena
            let inPer = diffPer perNew perOld
                outPer = diffPer perOld perNew
            mapM_ (sendA fid) $ atomicRemember arena inPer outPer sOld
            anySend fid perOld perNew
            sendA fid $ PerceptionA arena (pactors outPer) (pactors inPer)
          else anySend fid perOld perOld
        Left mfid ->
          -- @resets@ is false here and broken atomic has the same mfid
          when (isOurs fid mfid) $ sendUpdate fid atomic
  faction <- getsState sfaction
  mapM_ send $ EM.keys faction

atomicRemember :: LevelId -> Perception -> Perception -> State -> [CmdAtomic]
atomicRemember lid inPer outPer s =
  let inFov = ES.elems $ totalVisible inPer
      outFov = ES.elems $ totalVisible outPer
      lvl = sdungeon s EM.! lid
      actorD = sactorD s
      itemD = sitemD s
      pMaybe p = maybe Nothing (\x -> Just (p, x))
      inFloor = mapMaybe (\p -> pMaybe p $ EM.lookup p (lfloor lvl)) inFov
      fItem p (iid, k) = SpotItemA iid (itemD EM.! iid) k (CFloor lid p)
      fBag (p, bag) = map (fItem p) $ EM.assocs bag
      inItem = concatMap fBag inFloor
      -- No outItem, since items out of sight are not forgotten, unlike actors.
      -- The client will create atomic actions that forget remembered items
      -- that are revealed not to be there any more.
      atomicItem = inItem
      -- ++ items of actors; actually, we need to empty each actor,
      -- then createItemA; moveItemA --- can be optimized for old items;
      -- or add an atomic action that registers items and apply it to server s
      inPrio = mapMaybe (\p -> posToActor p lid s) inFov
      -- By this point the items of the actor are already registered in state.
      fActor aid = SpotActorA aid (actorD EM.! aid)
      inActor = map fActor inPrio
      outPrio = mapMaybe (\p -> posToActor p lid s) outFov
      gActor aid = LoseActorA aid (actorD EM.! aid)
      outActor = map gActor outPrio
      atomicActor = inActor ++ outActor
      inTileMap = map (\p -> (p, ltile lvl Kind.! p)) inFov
      fTile (p, nt) = (p, (undefined, nt))
      inTile = map fTile inTileMap
      -- No outTlie, since tiles out of sight are not forgotten, unlike actors.
      -- The client will create atomic actions that forget remembered tiles
      -- that are revealed not to be there any more.
      atomicTile = SpotTileA lid inTile
      -- @SpotTileA@ needs to be last, since it triggers client computation
      -- of a new FOV.
  in atomicItem ++ atomicActor ++ [atomicTile]

-- TODO: switch levels alternating between player factions,
-- if there are many and on distinct levels.
-- TODO: If a faction has no actors left in the dungeon,
-- announce game end for this faction. Not sure if here's the right place.
-- TODO: Let the spawning factions that remain duke it out somehow,
-- if the player requests to see it.
-- | If no actor of a non-spawning faction on the level,
-- switch levels. If no level to switch to, end game globally.
-- TODO: instead check if a non-spawn faction has Nothing leader. Equivalent.
checkEndGame :: (MonadAction m, MonadServerChan m) => m ()
checkEndGame = do
  -- Actors on the current level go first so that we don't switch levels
  -- unnecessarily.
  as <- getsState $ EM.elems . sactorD
  glo <- getState
  let aNotSp = filter (not . isSpawningFaction glo . bfaction) as
  case aNotSp of
    [] -> gameOver undefined undefined True  -- TODO: should send to all factions
    _ : _ -> return ()

-- | End game, showing the ending screens, if requested.
gameOver :: (MonadAction m, MonadServerChan m)
         => FactionId -> LevelId -> Bool -> m ()
gameOver fid arena showEndingScreens = do
  deepest <- getsLevel arena ldepth  -- TODO: use deepest visited instead of current
  let upd f = f {gquit = Just (False, Killed arena)}
  modifyState $ updateFaction (EM.adjust upd fid)
  when showEndingScreens $ do
    Kind.COps{coitem=Kind.Ops{oname, ouniqGroup}} <- getsState scops
    s <- getState
    depth <- getsState sdepth
    time <- undefined  -- TODO: sum over all levels? getsState getTime
    let (bag, total) = calculateTotal fid arena s
        failMsg | timeFit time timeTurn < 300 =
          "That song shall be short."
                | total < 100 =
          "Born poor, dies poor."
                | deepest < 4 && total < 500 =
          "This should end differently."
                | deepest < depth - 1 =
          "This defeat brings no dishonour."
                | deepest < depth =
          "That is your name. 'Almost'."
                | otherwise =
          "Dead heroes make better legends."
        currencyName = MU.Text $ oname $ ouniqGroup "currency"
        _loseMsg = makePhrase
          [ failMsg
          , "You left"
          , MU.NWs total currencyName
          , "and some junk." ]
    if EM.null bag
      then do
        let upd2 f = f {gquit = Just (True, Killed arena)}
        modifyState $ updateFaction (EM.adjust upd2 fid)
      else do
        -- TODO: do this for the killed factions, not for side
--        go <- sendQueryUI fid $ ConfirmShowItemsFloorCli loseMsg bag
--        when go $ do
          let upd2 f = f {gquit = Just (True, Killed arena)}
          modifyState $ updateFaction (EM.adjust upd2 fid)

-- | Perform moves for individual actors, as long as there are actors
-- with the next move time less than or equal to the current time.
-- Some very fast actors may move many times a clip and then
-- we introduce subclips and produce many frames per clip to avoid
-- jerky movement. Otherwise we push exactly one frame or frame delay.
-- We start by updating perception, because the selected level of dungeon
-- has changed since last time (every change, whether by human or AI
-- or @generateMonster@ is followd by a call to @handleActors@).
handleActors :: (MonadAction m, MonadServerChan m)
             => (FactionId -> CmdSer -> m [Atomic])
             -> LevelId
             -> Time  -- ^ start time of current subclip, exclusive
             -> m ()
handleActors cmdSerSem arena subclipStart = do
  Kind.COps{coactor} <- getsState scops
  time <- getsState $ getTime arena  -- the end time of this clip, inclusive
  prio <- getsLevel arena lprio
  quitS <- getsServer squit
  faction <- getsState sfaction
  s <- getState
  let mnext =
        if EM.null prio  -- wait until any actor spawned
        then Nothing
        else let -- Actors of the same faction move together.
                 -- TODO: insert wrt order, instead of sorting
                 isLeader (a1, b1) =
                   not $ Just a1 == gleader (faction EM.! bfaction b1)
                 order = Ord.comparing
                   (bfaction . snd &&& isLeader &&& bsymbol . snd)
                 (atime, as) = EM.findMin prio
                 ams = map (\a -> (a, getActorBody a s)) as
                 (actor, m) = head $ sortBy order ams
             in if atime > time
                then Nothing  -- no actor is ready for another move
                else Just (actor, m)
  case mnext of
    _ | quitS == Just True -> return ()  -- SaveBkp waits for clip end
    Nothing -> do
      when (subclipStart == timeZero) $
        mapM_ cmdAtomicBroad $ map (Right . DisplayDelayD) $ EM.keys faction
    Just (actor, body) | bhp body <= 0 && not (bproj body) -> do
      atoms <- cmdSerSem (bfaction body) $ DieSer actor
      mapM_ cmdAtomicBroad atoms
      -- Death is serious, new subclip.
      handleActors cmdSerSem arena (btime body)
    Just (actor, body) -> do
      let allPush =
            map (Right . DisplayPushD) $ EM.keys faction  -- TODO: too often
      mapM_ cmdAtomicBroad allPush  -- needs to be there before key presses
      let side = bfaction body
          mleader = gleader $ faction EM.! side
      isHuman <- getsState $ flip isHumanFaction side
      if Just actor == mleader && isHuman
        then do
          -- TODO: check that the command is legal, that is, correct side, etc.
          cmdS <- sendQueryUI side actor
          atoms <- cmdSerSem side cmdS
          let isFailure cmd = case cmd of Right FailureD{} -> True; _ -> False
              aborted = all isFailure atoms
              mleaderNew = aidCmdSer cmdS
              timed = timedCmdSer cmdS
              (leadAtoms, leaderNew) = case mleaderNew of
                Nothing -> assert (not timed) $ ([], actor)
                Just lNew | lNew /= actor ->
                  ([Left (LeadFactionA side mleader (Just lNew))], lNew)
                Just _ -> ([], actor)
          advanceAtoms <- if aborted || not timed
                          then return []
                          else advanceTime leaderNew
          let flush = [Right $ FlushFramesD side]
          mapM_ cmdAtomicBroad $ leadAtoms ++ atoms ++ advanceAtoms ++ flush
          if aborted then handleActors cmdSerSem arena subclipStart
          else do
            -- Advance time once, after the leader switched perhaps many times.
            -- TODO: this is correct only when all heroes have the same
            -- speed and can't switch leaders by, e.g., aiming a wand
            -- of domination. We need to generalize by displaying
            -- "(next move in .3s [RET]" when switching leaders.
            -- RET waits .3s and gives back control,
            -- Any other key does the .3s wait and the action form the key
            -- at once. This requires quite a bit of refactoring
            -- and is perhaps better done when the other factions have
            -- selected leaders as well.
            bNew <- getsState $ getActorBody leaderNew
            -- Human moves always start a new subclip.
            -- TODO: send messages with time (or at least DisplayPushCli)
            -- and then send DisplayPushCli only to actors that see _pos.
            -- Right now other need it too, to notice the delay.
            -- This will also be more accurate since now unseen
            -- simultaneous moves also generate delays.
            -- TODO: when changing leaders of different levels, if there's
            -- abort, a turn may be lost. Investigate/fix.
            handleActors cmdSerSem arena (btime bNew)
        else do
          cmdS <- sendQueryCliAI side actor
          atoms <- cmdSerSem side cmdS
          let isFailure cmd = case cmd of Right FailureD{} -> True; _ -> False
              aborted = all isFailure atoms
              mleaderNew = aidCmdSer cmdS
              timed = timedCmdSer cmdS
              (leadAtoms, leaderNew) = case mleaderNew of
                Nothing -> assert (not timed) $ ([], actor)
                Just lNew | lNew /= actor ->
                  ([Left (LeadFactionA side mleader (Just lNew))], lNew)
                Just _ -> ([], actor)
          advanceAtoms <- if aborted || not timed
                          then return []
                          else advanceTime leaderNew
          mapM_ cmdAtomicBroad $ leadAtoms ++ atoms ++ advanceAtoms
--          recordHistory
          let subclipStartDelta = timeAddFromSpeed coactor body subclipStart
          if not aborted && isHuman && not (bproj body)
             || subclipStart == timeZero
             || btime body > subclipStartDelta
            then
              -- Start a new subclip if its our own faction moving
              -- or it's another faction, but it's the first move of
              -- this whole clip or the actor has already moved during
              -- this subclip, so his multiple moves would be collapsed.
    -- If the following action aborts, we just advance the time and continue.
    -- TODO: or just fail at each abort in AI code? or use tryWithFrame?
              handleActors cmdSerSem arena (btime body)
            else
              -- No new subclip.
    -- If the following action aborts, we just advance the time and continue.
    -- TODO: or just fail at each abort in AI code? or use tryWithFrame?
              handleActors cmdSerSem arena subclipStart

-- | Advance the move time for the given actor.
advanceTime :: (MonadAction m, MonadServerChan m) => ActorId -> m [Atomic]
advanceTime aid = do
  Kind.COps{coactor} <- getsState scops
  b <- getsState $ getActorBody aid
  let speed = actorSpeed coactor b
      t = ticksPerMeter speed
  return [Left $ AgeActorA aid t]

-- | Continue or restart or exit the game.
endOrLoop :: (MonadAction m, MonadServerChan m)
          => m () -> m ()
endOrLoop loopServer = do
  quitS <- getsServer squit
  faction <- getsState sfaction
  let f (_, Faction{gquit=Nothing}) = Nothing
      f (fid, Faction{gquit=Just quit}) = Just (fid, quit)
  case (quitS, mapMaybe f $ EM.assocs faction) of
    (Just True, _) -> do
      -- Save and display in parallel.
    --      mv <- liftIO newEmptyMVar
      saveGameSer
    --      liftIO $ void
    --        $ forkIO (Save.saveGameSer config s ser `finally` putMVar mv ())
    -- 7.6        $ forkFinally (Save.saveGameSer config s ser) (putMVar mv ())
    --      tryIgnore $ do
    --        handleScores False Camping total
    --        broadcastUI [] $ MoreFullCli "See you soon, stronger and braver!"
            -- TODO: show the above
      broadcastCli GameDisconnectCli
    --      liftIO $ takeMVar mv  -- wait until saved
          -- Do nothing, that is, quit the game loop.
    (Just False, _) -> do
      broadcastCli GameSaveBkpCli
      saveGameBkp
      modifyServer $ \ser1 -> ser1 {squit = Nothing}
      loopServer
    (_, []) -> loopServer  -- just continue
    (_, (fid, quit) : _) -> do
      fac <- getsState $ (EM.! fid) . sfaction
      _total <- case gleader fac of
        Nothing -> return 0
        Just leader -> do
          b <- getsState $ getActorBody leader
          getsState $ snd . calculateTotal fid (blid b)
      -- The first, boolean component of quit determines
      -- if ending screens should be shown, the other argument describes
      -- the cause of the disruption of game flow.
      case quit of
        (_showScreens, _status@Killed{}) -> do
--           -- TODO: rewrite; handle killed faction, if human, mostly ignore if not
--           nullR <- undefined -- sendQueryCli fid NullReportCli
--           unless nullR $ do
--             -- Display any leftover report. Suggest it could be the death cause.
--             broadcastUI $ MoreBWUI "Who would have thought?"
--           tryWith
--             (\ finalMsg ->
--               let highScoreMsg = "Let's hope another party can save the day!"
--                   msg = if T.null finalMsg then highScoreMsg else finalMsg
--               in broadcastUI $ MoreBWUI msg
--               -- Do nothing, that is, quit the game loop.
--             )
--             (do
--                when showScreens $ handleScores fid True status total
--                go <- undefined  -- sendQueryUI fid
-- --                     $ ConfirmMoreBWUI "Next time will be different."
--                when (not go) $ abortWith "You could really win this time."
               restartGame loopServer
        (_showScreens, _status@Victor) -> do
          -- nullR <- undefined -- sendQueryCli fid NullReportCli
          -- unless nullR $ do
          --   -- Display any leftover report. Suggest it could be the master move.
          --   broadcastUI $ MoreFullUI "Brilliant, wasn't it?"
          -- when showScreens $ do
          --   tryIgnore $ handleScores fid True status total
          --   broadcastUI $ MoreFullUI "Can it be done better, though?"
          restartGame loopServer
        (_, Restart) -> restartGame loopServer
        (_, Camping) -> assert `failure` (fid, quit)

restartGame :: (MonadAction m, MonadServerChan m) => m () -> m ()
restartGame loopServer = do
  cops <- getsState scops
  gameReset cops
  initPer
  pers <- getsServer sper
  -- This state is quite small, fit for transmition to the client.
  -- The biggest part is content, which really needs to be updated
  -- at this point to keep clients in sync with server improvements.
  defLoc <- getsState localFromGlobal
  -- TODO: this is too hacky still
  funBroadcastCli (\fid -> CmdAtomicCli (RestartA fid (pers EM.! fid) defLoc))
  populateDungeon
  saveGameBkp
  loopServer

createFactions :: Kind.COps -> Config -> Rnd FactionDict
createFactions Kind.COps{ cofact=Kind.Ops{opick, okind}
                        , costrat=Kind.Ops{opick=sopick} } config = do
  let g isHuman (gname, fType) = do
        gkind <- opick fType (const True)
        let fk = okind gkind
            genemy = []  -- fixed below
            gally  = []  -- fixed below
            gquit = Nothing
        gAiLeader <-
          if isHuman
          then return Nothing
          else fmap Just $ sopick (fAiLeader fk) (const True)
        gAiMember <- sopick (fAiMember fk) (const True)
        let gleader = Nothing
        return Faction{..}
  lHuman <- mapM (g True) (configHuman config)
  lComputer <- mapM (g False) (configComputer config)
  let rawFs = zip [toEnum 1..] $ lHuman ++ lComputer
      isOfType fType fact =
        let fk = okind $ gkind fact
        in case lookup fType $ ffreq fk of
          Just n | n > 0 -> True
          _ -> False
      enemyAlly fact =
        let f fType = filter (isOfType fType . snd) rawFs
            fk = okind $ gkind fact
            setEnemy = ES.fromList $ map fst $ concatMap f $ fenemy fk
            setAlly  = ES.fromList $ map fst $ concatMap f $ fally fk
            genemy = ES.toList setEnemy
            gally = ES.toList $ setAlly ES.\\ setEnemy
        in fact {genemy, gally}
  return $! EM.fromDistinctAscList $ map (second enemyAlly) rawFs

gameReset :: (MonadAction m, MonadServer m) => Kind.COps -> m ()
gameReset cops@Kind.COps{coitem, corule, cotile} = do
  -- Rules config reloaded at each new game start.
  -- Taking the original config from config file, to reroll RNG, if needed
  -- (the current config file has the RNG rolled for the previous game).
  (sconfig, dungeonSeed, srandom) <- mkConfigRules corule
  let rnd :: Rnd (FactionDict, FlavourMap, Discovery, DiscoRev,
                  DungeonGen.FreshDungeon)
      rnd = do
        faction <- createFactions cops sconfig
        sflavour <- dungeonFlavourMap coitem
        (discoS, sdiscoRev) <- serverDiscos coitem
        freshDng <- DungeonGen.dungeonGen cops sconfig
        return (faction, sflavour, discoS, sdiscoRev, freshDng)
  let (faction, sflavour, discoS, sdiscoRev, DungeonGen.FreshDungeon{..}) =
        St.evalState rnd dungeonSeed
      defState = defStateGlobal freshDungeon freshDepth discoS faction cops
      defSer = emptyStateServer {sdiscoRev, sflavour, srandom, sconfig}
  putState defState
  putServer defSer
  -- Clients have no business noticing initial item creation, so we can
  -- do this here and evaluate with atomicSem, without notifying clients.
  let initialItems (lid, (Level{ltile}, citemNum)) = do
        nri <- rndToAction $ rollDice citemNum
        replicateM nri $ do
          pos <- rndToAction
                 $ findPos ltile (const (Tile.hasFeature cotile F.Boring))
          cmds <- execWriterT $ createItems 1 pos lid
          mapM_ atomicSem cmds
  mapM_ initialItems itemCounts

-- TODO: use rollSpawnPos in the inner loop
-- | Find starting postions for all factions. Try to make them distant
-- from each other and from any stairs.
findEntryPoss :: Kind.COps -> Level -> Int -> Rnd [Point]
findEntryPoss Kind.COps{cotile} Level{ltile, lxsize, lstair} k =
  let cminStairDist = chessDist lxsize (fst lstair) (snd lstair)
      dist l poss cmin =
        all (\pos -> chessDist lxsize l pos > cmin) poss
      tryFind _ 0 = return []
      tryFind ps n = do
        np <- findPosTry 20 ltile  -- 20 only, for unpredictability
                [ \ l _ -> dist l ps $ 2 * cminStairDist
                , \ l _ -> dist l ps cminStairDist
                , \ l _ -> dist l ps $ cminStairDist `div` 2
                , \ l _ -> dist l ps $ cminStairDist `div` 4
                , const (Tile.hasFeature cotile F.Walkable)
                ]
        nps <- tryFind (np : ps) (n - 1)
        return $ np : nps
      stairPoss = [fst lstair, snd lstair]
  in tryFind stairPoss k

-- Spawn initial actors. Clients should notice that so that they elect leaders.
populateDungeon :: (MonadAction m, MonadServerChan m) => m ()
populateDungeon = do
  -- TODO entryLevel should be defined per-faction in content
  let entryLevel = initialLevel
  lvl <- getsLevel entryLevel id
  cops <- getsState scops
  faction <- getsState sfaction
  config <- getsServer sconfig
  let notSpawning (_, fact) = not $ isSpawningFact cops fact
      needInitialCrew = map fst $ filter notSpawning $ EM.assocs faction
      heroNames = configHeroNames config : repeat []
      initialHeroes (side, ppos, heroName) = do
        replicateM_ (1 + configExtraHeroes config) $ do
          cmds <- execWriterT $ addHero side ppos entryLevel heroName
          mapM_ cmdAtomicBroad cmds
  entryPoss <- rndToAction $ findEntryPoss cops lvl (length needInitialCrew)
  mapM_ initialHeroes $ zip3 needInitialCrew entryPoss heroNames

-- * Assorted helper functions

-- | Generate a monster, possibly.
generateMonster :: (MonadAction m, MonadServerChan m) => LevelId -> m ()
generateMonster arena = do
  cops@Kind.COps{cofact=Kind.Ops{okind}} <- getsState scops
  pers <- getsServer sper
  lvl@Level{ldepth} <- getsLevel arena id
  faction <- getsState sfaction
  s <- getState
  let f fid = fspawn (okind (gkind (faction EM.! fid))) > 0
      spawns = actorNotProjList f arena s
  rc <- rndToAction $ monsterGenChance ldepth (length spawns)
  when rc $ do
    let allPers =
          ES.unions $ map (totalVisible . (EM.! arena)) $ EM.elems pers
    pos <- rndToAction $ rollSpawnPos cops allPers arena lvl s
    (_, cmds) <- runWriterT $ spawnMonsters 1 pos arena
    mapM_ cmdAtomicBroad cmds

-- | Create a new monster on the level, at a random position.
rollSpawnPos :: Kind.COps -> ES.EnumSet Point -> LevelId -> Level -> State
             -> Rnd Point
rollSpawnPos Kind.COps{cotile} visible lid lvl s = do
  let inhabitants = actorNotProjList (const True) lid s
      isLit = Tile.isLit cotile
      distantAtLeast d =
        \ l _ -> all (\ h -> chessDist (lxsize lvl) (bpos h) l > d) inhabitants
  findPosTry 40 (ltile lvl)
    [ \ _ t -> not (isLit t)
    , distantAtLeast 15
    , \ l t -> not (isLit t) || distantAtLeast 15 l t
    , distantAtLeast 10
    , \ l _ -> not $ l `ES.member` visible
    , distantAtLeast 5
    , \ l t -> Tile.hasFeature cotile F.Walkable t
               && unoccupied (actorList (const True) lid s) l
    ]

-- | Possibly regenerate HP for all actors on the current level.
--
-- We really want hero selection to be a purely UI distinction,
-- so all heroes need to regenerate, not just the leader.
-- Only the heroes on the current level regenerate (others are frozen
-- in time together with their level). This prevents cheating
-- via sending one hero to a safe level and waiting there.
regenerateLevelHP :: (MonadAction m, MonadServerChan m) => LevelId -> m ()
regenerateLevelHP arena = do
  Kind.COps{ coitem
           , coactor=Kind.Ops{okind}
           } <- getsState scops
  time <- getsState $ getTime arena
  discoS <- getsState sdisco
  s <- getState
  let pick (a, m) =
        let ak = okind $ bkind m
            itemAssocs = getActorItem a s
            regen = max 1 $
                      aregen ak `div`
                      case strongestRegen coitem discoS itemAssocs of
                        Just (_, i)  -> 5 * jpower i
                        Nothing -> 1
            bhpMax = maxDice (ahp ak)
            deltaHP = min 1 (bhpMax - bhp m)
        in if (time `timeFit` timeTurn) `mod` regen /= 0 || deltaHP <= 0
           then Nothing
           else Just a
  toRegen <-
    getsState $ catMaybes . map pick .actorNotProjAssocs (const True) arena
  mapM_ (\aid -> cmdAtomicBroad $ Left $ HealActorA aid 1) toRegen

-- TODO: let only some actors/items leave smell, e.g., a Smelly Hide Armour.
-- | Add a smell trace for the actor to the level.
_addSmell :: MonadActionRO m => ActorId -> WriterT [Atomic] m ()
_addSmell aid = do
  b <- getsState $ getActorBody aid
  time <- getsState $ getTime $ blid b
  oldS <- getsLevel (blid b) $ (EM.lookup $ bpos b) . lsmell
  let newTime = timeAdd time smellTimeout
  tellCmdAtomic $ AlterSmellA (blid b) [(bpos b, (oldS, Just newTime))]
