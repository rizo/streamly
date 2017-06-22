{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE ScopedTypeVariables       #-}

module Duct.Threads
    ( parallel
    , waitEvents
    , async
    , sample
    , sync
    --, react
    , threads
    )
where

import           Control.Applicative         ((<|>))
import           Control.Concurrent          (ThreadId, forkIO, killThread,
                                              myThreadId, threadDelay)
import           Control.Concurrent.STM      (TChan, atomically, newTChan,
                                              readTChan, tryReadTChan,
                                              writeTChan)
import           Control.Exception           (ErrorCall (..),
                                              SomeException (..), catch)
import qualified Control.Exception.Lifted    as EL
import           Control.Monad.Catch         (MonadThrow, throwM)
import           Control.Monad.IO.Class      (MonadIO (..))
import           Control.Monad.State         (get, gets, modify, put,
                                              runStateT, when)
import           Control.Monad.Trans.Class   (MonadTrans (lift))
import           Control.Monad.Trans.Control (MonadBaseControl, liftBaseWith)
import           Data.Dynamic                (Typeable)
import           Data.IORef                  (IORef, atomicModifyIORef,
                                              modifyIORef, newIORef, readIORef,
                                              writeIORef)
import           Data.List                   (delete)
import           Data.Maybe                  (fromJust)
import           Unsafe.Coerce               (unsafeCoerce)

import           Duct.AsyncT
import           Duct.Context

------------------------------------------------------------------------------
-- Model of computation
------------------------------------------------------------------------------

-- A computation starts in a top level thread. If no "forking primitives" are
-- used then the thread finishes in a straight line flow just like the IO
-- monad. However, if a "forking primitive" is used it "forks" the computation
-- into multiple flows.  The "forked" computations may run concurrently (and
-- therefore in parallel when possible) or serially. When multiple forking
-- primitives are composed it results into a tree of computations where each
-- branch of the tree can run concurrently.
--
-- A forking primitive may create multiple forks at that point, each fork
-- provides a specific input value to be used in the forked computation, this
-- value defines the fork.
--
-- The final result of the computation is the collection of all the values
-- generated by all the leaf level forks. These values are then propagated up
-- the tree and collected at the root of the tree.
--
-- Since AsyncT is a transformer we can use things like pipe, conduit or any
-- other transformer monads inside the computations to utilize single threaded
-- composition or data flow techniques.
--
------------------------------------------------------------------------------
-- Pick up from where we left in the previous thread
------------------------------------------------------------------------------

-- | Continue execution of the closure that we were executing when we migrated
-- to a new thread.

resume :: MonadIO m => Context -> m ()
resume ctx = do
        -- XXX rename to buildContext or buildState?
        let s = runAsyncT (resumeContext ctx)
        -- The returned value is always 'Nothing', we just discard it
        (_, c) <- runStateT s ctx

        -- XXX can we pass the result directly to the root thread instead of
        -- passing through all the parents? We can let the parent go away and
        -- handle the ChildDone events as well in the root thread.
        case parentChannel c of
            Nothing -> return () -- TODO: yield the value for streaming here
            Just chan ->  do
                let r = accumResults c
                when (length r /= 0) $
                    -- there is only one result in case of a non-root thread
                    -- XXX change the return type to 'a' instead of '[a]'
                    liftIO $ atomically $ writeTChan chan (PassOnResult (Right r))

------------------------------------------------------------------------------
-- Thread Management (creation, reaping and killing)
------------------------------------------------------------------------------

-- XXX We are using unbounded channels so this will not block on writing to
-- pchan. We can use bounded channels to throttle the creation of threads based
-- on consumption rate.
processOneEvent :: MonadIO m
    => ChildEvent a
    -> TChan (ChildEvent a)
    -> [ThreadId]
    -> Maybe SomeException
    -> m ([ThreadId], Maybe SomeException)
processOneEvent ev pchan pending exc = do
    e <- case exc of
        Nothing ->
            case ev of
                ChildDone tid res -> do
                    dbg $ "processOneEvent ChildDone: " ++ show tid
                    handlePass res
                PassOnResult res -> do
                    dbg $ "processOneEvent PassOnResult"
                    handlePass res
        Just _ -> return exc
    let p = case ev of
                ChildDone tid _ -> delete tid pending
                _ -> pending
    return (p, e)

    where

    handlePass :: MonadIO m
        => Either SomeException [a] -> m (Maybe SomeException)
    handlePass res =
        case res of
            Left e -> do
                    dbg $ "handlePass: caught exception"
                    liftIO $ mapM_ killThread pending
                    return (Just e)
            Right [] -> return Nothing
            Right _ -> do
                liftIO $ atomically $ writeTChan pchan
                    (PassOnResult (unsafeCoerce res))
                return Nothing

tryReclaimZombies :: (MonadIO m, MonadThrow m) => Context -> m ()
tryReclaimZombies ctx = do
    let pchan = fromJust (parentChannel ctx)
        cchan = childChannel ctx
        pendingRef = pendingThreads ctx

    pending <- liftIO $ readIORef pendingRef
    case pending of
        [] -> return ()
        _ ->  do
            mev <- liftIO $ atomically $ tryReadTChan cchan
            case mev of
                Nothing -> return ()
                Just ev -> do
                    (p, e) <- processOneEvent ev pchan pending Nothing
                    liftIO $ writeIORef pendingRef p
                    maybe (return ()) throwM e
                    tryReclaimZombies ctx

waitForOneEvent :: (MonadIO m, MonadThrow m) => Context -> m ()
waitForOneEvent ctx = do
    -- XXX assert pending must have at least one element
    -- assert that the tid is found in our list
    let pchan = fromJust (parentChannel ctx)
        cchan = childChannel ctx
        pendingRef = pendingThreads ctx

    ev <- liftIO $ atomically $ readTChan cchan
    pending <- liftIO $ readIORef pendingRef
    (p, e) <- processOneEvent ev pchan pending Nothing
    liftIO $ writeIORef pendingRef p
    maybe (return ()) throwM e

drainChildren :: MonadIO m
    => TChan (ChildEvent a)
    -> TChan (ChildEvent a)
    -> [ThreadId]
    -> Maybe SomeException
    -> m (Maybe SomeException)
drainChildren pchan cchan pending exc =
    if pending == []
        then return exc
        else do
            ev <- liftIO $ atomically $ readTChan cchan
            (p, e) <- processOneEvent ev pchan pending exc
            drainChildren pchan cchan p e

waitForChildren :: MonadIO m
    => Context -> Maybe SomeException -> m (Maybe SomeException)
waitForChildren ctx exc = do
    let pendingRef = pendingThreads ctx
        pchan = fromJust (parentChannel ctx)
    pending <- liftIO $ readIORef pendingRef
    e <- drainChildren pchan (childChannel ctx) pending exc
    liftIO $ writeIORef pendingRef []
    return e

-- | kill all the child threads associated with the continuation context
killChildren :: Context -> IO ()
killChildren ctx  = do
    ths <- readIORef (pendingThreads ctx)
    mapM_ killThread ths

-- XXX this is not a real semaphore as it does not really block on wait,
-- instead it returns whether the value is zero or non-zero.
--
waitQSemB :: IORef Int -> IO Bool
waitQSemB   sem = atomicModifyIORef sem $ \n ->
                    if n > 0
                    then (n - 1, True)
                    else (n, False)

signalQSemB :: IORef Int -> IO ()
signalQSemB sem = atomicModifyIORef sem $ \n -> (n + 1, ())

instance Read SomeException where
  readsPrec _n str = [(SomeException $ ErrorCall s, r)]
    where [(s , r)] = read str

-- Allocation of threads
--
-- global thread limit
-- thread fan-out i.e. per thread children limit
-- min per thread allocation to avoid starvation
--
-- dynamic adjustment based on the cost, speed of consumption, cpu utilization
-- etc. We need to adjust the limits based on cost, throughput and latencies.
--
-- The event producer thread must put the work on a work-queue and the child
-- threads can pick it up from there. But if there is just one consumer then it
-- may not make sense to have a separate producer unless the producing cost is
-- high.
--

forkFinally1 :: (MonadIO m, MonadBaseControl IO m) =>
    m a -> (Either SomeException a -> IO ()) -> m ThreadId
forkFinally1 action preExit =
    EL.mask $ \restore ->
        liftBaseWith $ \runInIO -> forkIO $ do
            _ <- runInIO $ EL.try (restore action) >>= liftIO . preExit
            return ()

-- | Run a given context in a new thread.
--
forkContextWith :: (MonadBaseControl IO m, MonadIO m, MonadThrow m)
    => (Context -> m (Maybe a)) -> Context -> m ()
forkContextWith runCtx context = do
    child <- childContext context
    tid <- forkFinally1 (runCtx child) (beforeExit child)
    updatePendingThreads context tid

    where

    updatePendingThreads :: (MonadIO m, MonadThrow m)
        => Context -> ThreadId -> m ()
    updatePendingThreads ctx tid = do
        -- update the new thread before reclaiming zombies so that if it exited
        -- already reclaim finds it in the list and does not panic.
        liftIO $ modifyIORef (pendingThreads ctx) $ (\ts -> tid:ts)
        tryReclaimZombies ctx

    childContext ctx = do
        pendingRef <- liftIO $ newIORef []
        chan <- liftIO $ atomically newTChan
        -- shares the threadCredit of the parent by default
        return $ ctx
            { parentChannel  = Just (childChannel ctx)
            , pendingThreads = pendingRef
            , childChannel = chan
            , accumResults = []
            }

    beforeExit ctx res = do
        tid <- myThreadId
        exc <- case res of
            Left e  -> do
                dbg $ "beforeExit: " ++ show tid ++ " caught exception"
                liftIO $ killChildren ctx
                return (Just e)
            Right Nothing -> return Nothing
            Right (Just _) -> error "Bug: should never happen"

        e <- waitForChildren ctx exc

        -- We are guaranteed to have a parent because we have been explicitly
        -- forked by some parent.
        let p = fromJust (parentChannel ctx)
        signalQSemB (threadCredit ctx)
        -- XXX change the return value type to Maybe SomeException
        liftIO $ atomically $ writeTChan p
            (ChildDone tid (maybe (Right []) Left e))

-- | A wrapper to first decide whether to run the context in the same thread or
-- a new thread and then run the context in that thread.
--
-- XXX create a canFork function
resumeContextWith :: (MonadBaseControl IO m, MonadIO m, MonadThrow m)
    => (Context -> m (Maybe a)) -> Context -> m ()
resumeContextWith runCtx context = do
    gotCredit <- liftIO $ waitQSemB (threadCredit context)
    pending <- liftIO $ readIORef $ pendingThreads context
    case gotCredit of
        False -> case pending of
                [] -> do
                    _ <- runCtx context -- run synchronously
                    return ()
                _ -> do
                        -- XXX If we have unreclaimable child threads e.g.
                        -- infinite loop, this is going to deadlock us. We need
                        -- special handling for those cases. Add those to
                        -- unreclaimable list? And always execute them in an
                        -- async thread, cannot use sync for those.
                        waitForOneEvent context
                        resumeContextWith runCtx context
        True -> forkContextWith runCtx context

-- | 'StreamData' represents a task in a task stream being generated.
data StreamData a =
      SMore a               -- ^ More tasks to come
    | SLast a               -- ^ This is the last task
    | SDone                 -- ^ No more tasks, we are done
    | SError SomeException  -- ^ An error occurred
    deriving (Typeable, Show,Read)

-- The current model is to start a new thread for every task. The input is
-- provided at the time of the creation and therefore no synchronization is
-- needed compared to a pool of threads contending to get the input from a
-- channel. However the thread creation overhead may be more than the
-- synchronization cost?
--
-- When the task is over the outputs need to be collected and that requires
-- synchronization irrespective of a thread pool model or per task new thread
-- model.
--
-- XXX instead of starting a new thread every time, reuse the existing child
-- threads and send them work via a shared channel. When there is no more work
-- available we need a way to close the channel and wakeup all waiters so that
-- they can go away rather than waiting indefinitely.
--
-- | Execute the IO action, resume the saved context with the output of the io
-- action.
loopContextWith ::  (MonadIO m, MonadBaseControl IO m, MonadThrow m)
    => IO (StreamData t) -> Context -> m (Maybe a)
loopContextWith ioaction ctx = do
    streamData <- liftIO $ ioaction `catch`
            \(e :: SomeException) -> return $ SError e

    let ctx' = setContextMailBox ctx streamData
    case streamData of
        SMore _ -> do
            resumeContextWith (\x -> resume x >> return Nothing) ctx'
            loopContextWith ioaction ctx
        _ -> do
            resume ctx' -- run synchronously
            return Nothing -- we are done with the loop

-- | Run an IO action one or more times to generate a stream of tasks. The IO
-- action returns a 'StreamData'. When it returns an 'SMore' or 'SLast' a new
-- task is triggered with the result value. If the return value is 'SMore', the
-- action is run again to generate the next task, otherwise task creation
-- stops.
--
-- Unless the maximum number of threads (set with 'threads') has been reached,
-- the task is generated in a new thread and the current thread returns a void
-- task.
parallel  :: (Monad m, MonadIO m, MonadBaseControl IO m, MonadThrow m)
    => IO (StreamData a) -> AsyncT m (StreamData a)
parallel ioaction = AsyncT $ do
    -- We retrieve the context here and pass it on so that we can resume it
    -- later. Control resumes at this place when we resume this context in a
    -- new thread or in the same thread after generating the event data from
    -- the ioaction.
    mb <- takeContextMailBox
    case mb of
        -- We have already executed the ioaction in the parent thread and put
        -- its result in the context and now we are continuing the context in a
        -- new thread. Just return the result of the ioaction stored in the
        -- 'event' field.
        Right x -> return (Just x)

        -- We have to execute the io action, generate event data, put it in the
        -- context mailbox and then continue from the point where this context
        -- was retreieved, in this thread or a new thread.
        Left ctx -> do
            lift $ resumeContextWith (loopContextWith ioaction) ctx

            -- We will never reach here if we continued the context in the same
            -- thread. If we started a new thread then the parent thread
            -- reaches here.
            loc <- getLocation
            when (loc /= RemoteNode) $ setLocation WaitingParent
            return Nothing

-- | An task stream generator that produces an infinite stream of tasks by
-- running an IO computation in a loop. A task is triggered carrying the output
-- of the computation. See 'parallel' for notes on the return value.
waitEvents :: (MonadIO m, MonadBaseControl IO m, MonadThrow m)
    => IO a -> AsyncT m a
waitEvents io = do
  mr <- parallel (SMore <$> io)
  case mr of
    SMore  x -> return x
 --   SError e -> back e

-- | Run an IO computation asynchronously and generate a single task carrying
-- the result of the computation when it completes. See 'parallel' for notes on
-- the return value.
async  :: (MonadIO m, MonadBaseControl IO m, MonadThrow m)
    => IO a -> AsyncT m a
async io = do
  mr <- parallel (SLast <$> io)
  case mr of
    SLast  x -> return x
  --  SError e -> back   e

-- | Force an async computation to run synchronously. It can be useful in an
-- 'Alternative' composition to run the alternative only after finishing a
-- computation.  Note that in Applicatives it might result in an undesired
-- serialization.
sync :: MonadIO m => AsyncT m a -> AsyncT m a
sync x = AsyncT $ do
  setLocation RemoteNode
  r <- runAsyncT x
  setLocation Worker
  return r

-- | An task stream generator that produces an infinite stream of tasks by
-- running an IO computation periodically at the specified time interval. The
-- task carries the result of the computation.  A new task is generated only if
-- the output of the computation is different from the previous one.  See
-- 'parallel' for notes on the return value.
sample :: (Eq a, MonadIO m, MonadBaseControl IO m, MonadThrow m)
    => IO a -> Int -> AsyncT m a
sample action interval = do
  v    <- liftIO action
  prev <- liftIO $ newIORef v
  waitEvents (loop action prev) <|> async (return v)
  where loop act prev = loop'
          where loop' = do
                  threadDelay interval
                  v  <- act
                  v' <- readIORef prev
                  if v /= v' then writeIORef prev v >> return v else loop'

-- | Make a transient task generator from an asynchronous callback handler.
--
-- The first parameter is a callback. The second parameter is a value to be
-- returned to the callback; if the callback expects no return value it
-- can just be a @return ()@. The callback expects a setter function taking the
-- @eventdata@ as an argument and returning a value to the callback; this
-- function is supplied by 'react'.
--
-- Callbacks from foreign code can be wrapped into such a handler and hooked
-- into the transient monad using 'react'. Every time the callback is called it
-- generates a new task for the transient monad.
--
{-
react
  :: (Monad m, MonadIO m)
  => ((eventdata ->  m response) -> m ())
  -> IO  response
  -> AsyncT m eventdata
react setHandler iob = AsyncT $ do
        context <- get
        case event context of
          Nothing -> do
            lift $ setHandler $ \dat ->do
              resume (updateContextEvent context dat)
              liftIO iob
            loc <- getLocation
            when (loc /= RemoteNode) $ setLocation WaitingParent
            return Nothing

          j@(Just _) -> do
            put context{event=Nothing}
            return $ unsafeCoerce j

-}

------------------------------------------------------------------------------
-- Controlling thread quota
------------------------------------------------------------------------------

-- XXX Should n be Word32 instead?
-- | Runs a computation under a given thread limit.  A limit of 0 means new
-- tasks start synchronously in the current thread.  New threads are created by
-- 'parallel', and APIs that use parallel.
threads :: MonadIO m => Int -> AsyncT m a -> AsyncT m a
threads n process = do
   oldCr <- gets threadCredit
   newCr <- liftIO $ newIORef n
   modify $ \s -> s { threadCredit = newCr }
   r <- process
        <** (modify $ \s -> s { threadCredit = oldCr }) -- restore old credit
   return r

{-
-- | Run a "non transient" computation within the underlying state monad, so it
-- is guaranteed that the computation neither can stop nor can trigger
-- additional events/threads.
noTrans :: Monad m => StateM m x -> AsyncT m x
noTrans x = AsyncT $ x >>= return . Just

-- This can be used to set, increase or decrease the existing limit. The limit
-- is shared by multiple threads and therefore needs to modified atomically.
-- Note that when there is no limit the limit is set to maxBound it can
-- overflow with an increment and get reduced instead of increasing.
-- XXX should we use a Maybe instead? Or use separate inc/dec/set APIs to
-- handle overflow properly?
--
-- modifyThreads :: MonadIO m => (Int -> Int) -> AsyncT m ()
-- modifyThreads f =
-}
