{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns, BangPatterns #-}

{-|

Thread-safe Logging with bonus controlled-schedule debugging capabilities.

This module supports logging to memory, serializing messages and deferring the work
of actually printing them.  Another thread can flush the logged messages at its
leisure.

The second capability of this infrastructure is to use the debugging print messages
as points at which to gate the execution of the program.  That is, each `logStrLn_`
call becomes a place where the program blocks and checks in with a central
coordinator, which only allows one thread to unblock at a time.  Thus, if there are
sufficient debug logging messages in the program, this can enable a form of
deterministic replay (and quickcheck-style testing of different interleavings).

 -}

module Control.LVish.Logging
       (

         -- * Global variables
         dbgLvl, 

         -- * New logger interface
         newLogger, logOn, Logger(closeIt), WaitMode(..), LogMsg(..),

         -- * General utilities
         forkWithExceptions
       )
       where

import           Control.Monad
import qualified Control.Exception as E
import qualified Control.Concurrent.Async as A
import           Data.IORef
import           Data.List (sortBy)
import           GHC.Conc hiding (yield)
import           Control.Concurrent
import           System.IO.Unsafe (unsafePerformIO)
import           System.IO (stderr, stdout, hFlush, hPutStrLn)
import           System.Environment(getEnvironment)
import           System.Random
import           Text.Printf (printf, hPrintf)
import           Debug.Trace (trace, traceEventIO)

import Control.LVish.Types
-- import qualified Control.LVish.SchedIdempotentInternal as Sched

----------------------------------------------------------------------------------------------------

-- | A Logger coordinates a set of threads that print debug logging messages.
--
--   This are abstract objects supporting only the operations provided by this module
--   and the non-hidden fields of the Logger.
data Logger = Logger { coordinator :: A.Async () -- ThreadId
                                      -- ^ (private) The thread that chooses which action to unblock next
                                      -- and handles printing to the screen as well.
                     , minLvl :: Int  -- ^ The minimum level of messages accepted by this logger (usually 0).
                     , maxLvl :: Int  -- ^ The maximum level of messages accepted by this logger.
                     , checkPoint :: SmplChan Writer -- ^ The serialized queue of writers attempting to log dbg messages.
--                     , logged :: IORef [LogMsg] -- ^ (private) The actual log of messages.
                     , closeIt :: IO () -- ^ (public) A method to complete flushing, close down the helper thread,
                                        -- and generally wrap up.
                     , waitWorkers :: WaitMode
                     }

-- | A single thread attempting to log a message.  It only unblocks when the attached
-- MVar is filled.
data Writer = Writer { who :: String
                     , continue :: MVar ()
                     , msg :: LogMsg
                       -- TODO: Indicate whether this writer has useful work to do or
                       -- is about to block... this provides a simple notion of
                       -- priority.
                     }

-- | Several different ways we know to wait for quiescence in the concurrent mutator
-- before proceeding.
data WaitMode = WaitTids [ThreadId] (IO Bool)
                -- ^ Wait until a certain set of threads is blocked before proceeding.
                --   If that conditional holds ALSO make sure the provided polling action
                --   returns True as well.
              | WaitDynamic -- ^ UNFINISHED: Dynamically track tasks/workers.  The
                            -- num workers starts at 1 and then is modified
                            -- with `incrTasks` and `decrTasks`.
              | WaitNum {
                numThreads  :: Int,   -- ^ How many threads total must check in?
                downThreads :: IO Int -- ^ Poll how many threads won't participate this round.
                } -- ^ A fixed set of threads must check-in each round before proceeding.
  deriving Show

instance Show (IO Bool) where
  show _ = "<IO Bool>"
  
instance Show (IO Int) where
  show _ = "<IO Int>"

-- | We allow logging in O(1) time in String or ByteString format.  In practice the
-- distinction is not that important, because only *thunks* should be logged; the
-- thread printing the logs should deal with forcing those thunks.
data LogMsg = StrMsg { lvl::Int, body::String }
--          | ByteStrMsg { lvl::Int,  }

toString x@(StrMsg{}) = body x

maxWait :: Int
maxWait = 10*1000 -- 10ms

andM :: [IO Bool] -> IO a -> IO a -> IO a
andM [] t _f = t
andM (hd:tl) t f = do
  b <- hd
  if b then andM tl t f
       else f

catchAll :: ThreadId -> E.SomeException -> IO ()
catchAll parent exn =
  case E.fromException exn of 
    Just E.ThreadKilled -> return ()
    _ -> do
     hPutStrLn stderr ("! Exception on Logger thread: "++show exn)
     hFlush stderr
     E.throwTo parent exn
     E.throwIO exn

--------------------------------------------------------------------------------

-- | Create a new logger, which includes forking a coordinator thread.
--   Takes as argument the number of worker threads participating in the computation.
newLogger :: Maybe (Int,Int) -- ^ What inclusive range of messages do we accept?  Defaults to `(0,dbgLvl)`.
             -> WaitMode
             -> IO Logger
newLogger Nothing w = newLogger (Just (0,dbgLvl)) w
newLogger (Just (minLvl, maxLvl)) waitWorkers = do 
  logged      <- newIORef []
  checkPoint  <- newSmplChan
  parent      <- myThreadId
  coordinator <- A.async $ E.handle (catchAll parent) $ do
    -- Proceed in rounds, gather the set of actions that may happen in parallel, then
    -- pick one.  We log the series of decisions we make for reproducability.
    let schedloop !iters !num !waiting !bkoff = do
          when (iters > 0 && iters `mod` 500 == 0) $
            putStrLn $ "Warning: logger has spun for "++show iters++" iterations, "++show num++" are waiting."
          hFlush stdout
          
          let keepWaiting = do b <- backoff bkoff
                               schedloop (iters+1) num waiting b
              waitMore    = do w <- readSmplChan checkPoint -- Blocking! (or spinning)
                               b <- newBackoff maxWait -- We got something, reset this.
                               schedloop (iters+1) (num+1) (w:waiting) b
          case waitWorkers of
            WaitNum target extra -> do
              n <- extra -- Atomically check how many extra workers are blocked.
              if (num + n >= target)
                then pickAndProceed waiting
                else waitMore
            WaitTids tids poll -> do
              -- FIXME: This is not watertight... it will work with high probability but can't be trusted:
              andM [checkTids tids, poll, checkTids tids, poll]
                   (do ls <- flushChan waiting
                       case ls of
                         [] -> do chatter " [Logger] Warning: No active tasks?"
                                  bk2 <- backoff bkoff
                                  schedloop (iters+1) 0 [] bk2
                         _ -> pickAndProceed ls)
                   keepWaiting

        -- When all threads are quiescent, we can flush the remaining messagers from
        -- the channel to get the whole set of waiting tasks.
        flushChan !acc = do
          x <- tryReadSmplChan checkPoint
          case x of
            Just h  -> flushChan (h:acc)
            Nothing -> return acc

        -- Take the set of logically-in-parallel tasks, choose one, execute it, and
        -- then return to the main scheduler loop.
        pickAndProceed [] = error "pickAndProceed: this should only be called on a non-empty list"
        pickAndProceed waiting = do
          let order a b =
                let s1 = toString (msg a)
                    s2 = toString (msg b) in
                case compare s1 s2 of
                  GT -> GT
                  LT -> LT
                  EQ -> error $" [Logger] Need in-parallel log messages to have an ordering, got two equal:\n "++s1
              sorted = sortBy order waiting
              len = length waiting
          -- For now let's randomly pick an action:
          pos <- randomRIO (0,len-1)
          let pick = sorted !! pos
              (pref,suf) = splitAt pos sorted
              rst = pref ++ tail suf
          unblockTask pos len pick -- The task will asynchronously run when it can.
          yield -- If running on one thread, give it a chance to run.
          -- Return to the scheduler to wait for the next quiescent point:
          bnew <- newBackoff maxWait
          tid <- myThreadId
          schedloop 0 (length rst) rst bnew

        unblockTask pos len Writer{who,continue,msg} = do
          let str = show (lvl msg)++ "| #"++show (1+pos)++" of "++show len ++": "++ toString msg
          -- Print out the message:
          hPrintf stderr "%s\n" str
          traceEventIO str
          -- Signal that the thread may continue.
          putMVar continue ()
          
        -- Check whether the worker threads are all quiesced 
        checkTids [] = return True
        checkTids (tid:rst) = do 
          st <- threadStatus tid
          case st of
            ThreadRunning   -> return False
            ThreadFinished  -> checkTids rst
            -- WARNING: this design is flawed because it is possible when compiled
            -- with -threaded that IO will spuriously showed up as BlockedOnMVar:
            ThreadBlocked BlockedOnMVar -> checkTids rst
            ThreadBlocked _ -> return False
            ThreadDied      -> checkTids rst -- Should this be an error condition!?
    schedloop 0 0 [] =<< newBackoff maxWait -- Kick things off.
    return () -- End: async thread
  let closeIt = A.cancel coordinator
  return $! Logger { coordinator, checkPoint, closeIt, waitWorkers, minLvl, maxLvl } -- logged, 

chatter :: String -> IO ()
-- chatter = hPrintf stderr
-- chatter = printf "%s\n"
chatter _ = return ()

printNTrace s = do putStrLn s; traceEventIO s; hFlush stdout

-- UNFINISHED:
incrTasks = undefined
decrTasks = undefined

-- | Write a log message from the current thread, IF the level of the
-- message falls into the range accepted by the given `Logger`,
-- otherwise, the message is ignored.
logOn :: Logger -> LogMsg -> IO ()
logOn Logger{checkPoint,minLvl,maxLvl} msg
  | (minLvl <= lvl msg) && (lvl msg <= maxLvl) = do
     continue <- newEmptyMVar
     writeSmplChan checkPoint Writer{who="",continue,msg}
     takeMVar continue -- Block until we're given permission to proceed.
  | otherwise = return ()

----------------------------------------------------------------------------------------------------
-- Simple back-off strategy.

-- | The state for an exponential backoff.
data Backoff = Backoff { current :: !Int
                       , cap :: !Int  -- ^ Maximum nanoseconds to wait.
                       }
  deriving Show


newBackoff :: Int -> IO Backoff
newBackoff cap = return Backoff{cap,current=0}

backoff :: Backoff -> IO Backoff
-- backoff b = do yield; return b
backoff Backoff{current,cap} =                                   
  case current of
    -- Yield once before we start delaying:
    0 -> do yield
            return Backoff{cap,current=1}
    n -> do let next = min cap (2*n)
            threadDelay n
            return Backoff{cap,current=next}
  
----------------------------------------------------------------------------------------------------
-- Simple channels: we need non-blocking reads so we can't use
-- Control.Concurrent.Chan.  We could use TChan, but I don't want to bring STM into
-- it right now.

-- type MyChan a = Chan a

-- -- | A simple channel.  Take-before-put is the protocol.
-- type SmplChan a = MVar [a]

-- | Simple channels that don't support real blocking.
type SmplChan a = IORef [a]

newSmplChan :: IO (SmplChan a)
newSmplChan = newIORef []

-- | Non-blocking read.
tryReadSmplChan :: SmplChan a -> IO (Maybe a)
tryReadSmplChan ch = do
  x <- atomicModifyIORef' ch $ \ ls -> 
       case ls of
         []  -> ([], Nothing)
         h:t -> (t, Just h)
  return x

-- | Blocking OR busy-waiting read.
readSmplChan :: SmplChan a -> IO a
readSmplChan ch = loop =<< newBackoff maxWait
 where
   loop bk = do
     x <- tryReadSmplChan ch
     case x of
       Nothing -> do b2 <- backoff bk
                     loop b2
       Just h  -> return h

-- | Always succeeds.  Asynchronous write to channel.
writeSmplChan :: SmplChan a -> a -> IO ()
writeSmplChan ch x = do
  atomicModifyIORef' ch $ \ ls -> (x:ls,())

----------------------------------------------------------------------------------------------------

{-# NOINLINE theEnv #-}
theEnv :: [(String, String)]
theEnv = unsafePerformIO getEnvironment

-- | Debugging flag shared by several modules.
--   This is activated by setting the environment variable @DEBUG=1..5@.
-- 
--   By convention @DEBUG=100@ turns on full sequentialization of the program and
--   control over the interleavings in concurrent code, enabling systematic debugging
--   of concurrency problems.
dbgLvl :: Int
#ifdef DEBUG_LVAR
{-# NOINLINE dbgLvl #-}
dbgLvl = case lookup "DEBUG" theEnv of
       Nothing  -> defaultDbg
       Just ""  -> defaultDbg
       Just "0" -> defaultDbg
       Just s   ->
         case reads s of
           ((n,_):_) -> trace (" [!] LVish responding to env Var: DEBUG="++show n) n
           [] -> error$"Attempt to parse DEBUG env var as Int failed: "++show s
#else 
{-# INLINE dbgLvl #-}
dbgLvl = 0
#endif

defaultDbg :: Int
defaultDbg = 0

replayDbg :: Int
replayDbg = 100


-- | Exceptions that walk up the fork-tree of threads.
--   
--   WARNING: By holding onto the ThreadId we keep the parent thread from being
--   garbage collected (at least as of GHC 7.6).  This means that even if it was
--   complete, it will still be hanging around to accept the exception below.
forkWithExceptions :: (IO () -> IO ThreadId) -> String -> IO () -> IO ThreadId
forkWithExceptions forkit descr action = do 
   parent <- myThreadId
   forkit $ do
      tid <- myThreadId
      E.catch action 
	 (\ e -> 
           case E.fromException e of 
             Just E.ThreadKilled -> do
-- Killing worker threads is normal now when exception handling, so this chatter is restricted to debug mode:
#ifdef DEBUG_LVAR
               printf "\nThreadKilled exception inside child thread, %s (not propagating!): %s\n" (show tid) (show descr)
#endif
               return ()
	     _  -> do
#ifdef DEBUG_LVAR               
                      printf "\nException inside child thread %s, %s: %s\n" (show descr) (show tid) (show e)
#endif
                      E.throwTo parent (e :: E.SomeException)
	 )
