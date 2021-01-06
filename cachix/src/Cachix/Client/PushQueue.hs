{- Implements a queue with the following properties:

- waits for queue to be fully pushed when exiting using ctrl-c (SIGINT)
- allows stopping the producer
- avoid duplicate pushing of the same store paths

To safetly exit on demand, signal SIGINT.
-}
module Cachix.Client.PushQueue
  ( startWorkers,
    Queue,
  )
where

import qualified Cachix.Client.Push as Push
import Cachix.Client.Retry (retryAll)
import Control.Concurrent.Async
import Control.Concurrent.STM (TVar, modifyTVar', newTVarIO, readTVar)
import qualified Control.Concurrent.STM.Lock as Lock
import qualified Control.Concurrent.STM.TBQueue as TBQueue
import qualified Data.Set as S
import Protolude
import qualified System.Posix.Signals as Signals

type StorePath = Text

type Queue = TBQueue.TBQueue StorePath

data PushWorkerState
  = PushWorkerState
      { pushQueue :: Queue,
        inProgress :: TVar Int
      }

data QueryWorkerState
  = QueryWorkerState
      { queryQueue :: Queue,
        alreadyQueued :: S.Set StorePath,
        lock :: Lock.Lock
      }

worker :: Push.PushCache IO () -> PushWorkerState -> IO ()
worker pushCache workerState = forever $ do
  storePath <- atomically $ TBQueue.readTBQueue $ pushQueue workerState
  bracket_ (inProgresModify (+ 1)) (inProgresModify (\x -> x - 1))
    $ retryAll
    $ Push.uploadStorePath pushCache storePath
  where
    inProgresModify f =
      atomically $ modifyTVar' (inProgress workerState) f

-- NOTE: producer is responsible for signaling SIGINT upon termination
-- NOTE: producer should return an `IO ()` that should be a blocking operation for terminating it
startWorkers :: Int -> (Queue -> IO (IO ())) -> Push.PushCache IO () -> IO ()
startWorkers numWorkers mkProducer pushCache = do
  -- start query worker
  (newQueryQueue, newPushQueue, newLock) <-
    atomically $
      (,,) <$> TBQueue.newTBQueue 10000 <*> TBQueue.newTBQueue 10000 <*> Lock.new
  let queryWorkerState = QueryWorkerState newQueryQueue S.empty newLock
  queryWorker <- async $ queryLoop queryWorkerState newPushQueue pushCache
  -- start push workers
  stopProducerCallback <- mkProducer newQueryQueue
  progress <- newTVarIO 0
  let pushWorkerState = PushWorkerState newPushQueue progress
  pushWorker <- async $ replicateConcurrently_ numWorkers $ worker pushCache pushWorkerState
  void $ Signals.installHandler Signals.sigINT (Signals.CatchOnce (exitOnceQueueIsEmpty stopProducerCallback pushWorker queryWorker queryWorkerState pushWorkerState)) Nothing
  waitEither_ pushWorker queryWorker

queryLoop :: QueryWorkerState -> Queue -> Push.PushCache IO () -> IO ()
queryLoop workerState pushqueue pushCache = do
  -- this blocks until item is available and doesn't remove it from the queue
  _ <- atomically $ TBQueue.peekTBQueue (queryQueue workerState)
  (missingStorePathsSet, alreadyQueuedSet) <- Lock.with (lock workerState) $ do
    storePaths <- atomically $ TBQueue.flushTBQueue (queryQueue workerState)
    -- if push queue is empty we can our store path cache here as getClosure will do its job
    alreadyQueuedSet <- atomically $ do
      isEmpty <- TBQueue.isEmptyTBQueue pushqueue
      if isEmpty
        then return S.empty
        else return $ alreadyQueued workerState
    missingStorePaths <- Push.getClosure pushCache storePaths
    let missingStorePathsSet = S.fromList missingStorePaths
        uncachedMissingStorePaths = S.difference missingStorePathsSet alreadyQueuedSet
    atomically $ for_ uncachedMissingStorePaths $ TBQueue.writeTBQueue pushqueue
    return (missingStorePathsSet, alreadyQueuedSet)
  queryLoop (workerState {alreadyQueued = S.union missingStorePathsSet alreadyQueuedSet}) pushqueue pushCache

exitOnceQueueIsEmpty :: IO () -> Async () -> Async () -> QueryWorkerState -> PushWorkerState -> IO ()
exitOnceQueueIsEmpty stopProducerCallback pushWorker queryWorker queryWorkerState pushWorkerState = do
  putText "Stopping producer of store paths and waiting for queue to empty ..."
  stopProducerCallback
  go
  where
    go = do
      (isDone, inprogress, queueLength) <- atomically $ do
        pushQueueLength <- TBQueue.lengthTBQueue $ pushQueue pushWorkerState
        queryQueueLength <- TBQueue.lengthTBQueue $ queryQueue queryWorkerState
        inprogress <- readTVar $ inProgress pushWorkerState
        isLocked <- Lock.locked (lock queryWorkerState)
        let isDone = pushQueueLength == 0 && queryQueueLength == 0 && inprogress == 0 && not isLocked
        return (isDone, inprogress, pushQueueLength)
      if isDone
        then do
          putText "All done, exiting."
          cancelWith pushWorker UserInterrupt
          cancelWith queryWorker UserInterrupt
        else do
          putText $ "Waiting to finish: " <> show inprogress <> " pushing, " <> show queueLength <> " in queue"
          threadDelay (1000 * 1000)
          go
