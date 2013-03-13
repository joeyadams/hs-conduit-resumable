-- |
-- Stability: experimental
module Data.Conduit.Resumable (
    -- * Resumable sources
    ResumableSource,
    newResumableSource,
    ($$+),
    ($$++),
    ($$+-),

    -- * Resumable sinks
    -- $sink
    (+$$),

    -- * Resumable conduits
    ResumableConduit,
    newResumableConduit,
    (=$+),
    (=$++),
    (=$+-),
) where

import Control.Monad
import Control.Monad.Trans.Class (lift)
import Data.Conduit
import Data.Conduit.Internal
import Data.Void

-- ResumableSource (same fixity as $$)
-- infixr 0 $$+
-- infixr 0 $$++
-- infixr 0 $$+-

-- ResumableSink (same fixity as $$)
infixr 0 +$$

-- Not implemented yet
-- ResumableConduit left fusion (same fixity as $=)
-- infixl 1 +$=
-- infixl 1 ++$=
-- infixl 1 -+$=

-- ResumableConduit right fusion (same fixity as =$ and =$=)
infixr 2 =$+
infixr 2 =$++
infixr 2 =$+-

------------------------------------------------------------------------
-- Resumable sources

-- ResumableSource is defined in Data.Conduit.Internal:
-- data ResumableSource m o = ResumableSource (Source m o) (m ())

-- | Convert a 'Source' into a 'ResumableSource' so it can be used with '$$++'.
newResumableSource :: Monad m => Source m o -> ResumableSource m o
newResumableSource src = ResumableSource src (return ())

------------------------------------------------------------------------
-- Resumable sinks

-- $sink
--
-- There is no \"ResumableSink\" type because 'Sink' does not require finalizer
-- support.  A 'Sink' is finalized by letting it run to completion with '$$'.

-- | Connect a source and a sink, allowing the sink to be fed more data later.
-- Return a 'Right' if the sink completes, or a 'Left' if the source is
-- exhausted and the sink requests more input.
--
-- When you are done with the sink, close it with '$$' so that:
--
--  * The sink sees the end of stream.  The sink never sees
--    'Data.Conduit.await' return 'Nothing' until you finish the sink
--    with '$$'.
--
--  * The sink can release system resources.
(+$$) :: Monad m
      => Source m i
      -> Sink i m r
      -> m (Either (Sink i m r) r)
(+$$) (ConduitM left0) (ConduitM right0) =
    goRight (return ()) left0 right0
  where
    goRight final left right =
        case right of
            HaveOutput _ _ o  -> absurd o
            NeedInput rp rc   -> goLeft rp rc final left
            Done r            -> final >> return (Right r)
            PipeM mp          -> mp >>= goRight final left
            Leftover p i      -> goRight final (HaveOutput left final i) p

    goLeft rp rc final left =
        case left of
            HaveOutput left' final' o -> goRight final' left' (rp o)
            NeedInput _ lc            -> recurse (lc ())
            Done _                    -> return $ Left $
                                         ConduitM $ NeedInput rp rc
            PipeM mp                  -> mp >>= recurse
            Leftover p _              -> recurse p
      where
        recurse = goLeft rp rc final

------------------------------------------------------------------------
-- Resumable conduits

data ResumableConduit i m o = ResumableConduit (Pipe i i o () m ()) (m ())

-- | Convert a 'Conduit' into a 'ResumableConduit' so it can be used with '=$++'.
newResumableConduit :: Monad m => Conduit i m o -> ResumableConduit i m o
newResumableConduit (ConduitM p) = ResumableConduit p (return ())

-- | Fuse a conduit behind a sink, but allow the conduit to be reused after
-- the sink returns.
--
-- When the source runs out, the stream terminator is sent directly to
-- the sink, bypassing the conduit.  Some conduits wait for a stream terminator
-- before producing their remaining output, so be sure to use '=$+-'
-- to \"flush\" this data out.
(=$+) :: Monad m
      => Conduit a m b
      -> Sink b m r
      -> Sink a m (ResumableConduit a m b, r)
(=$+) conduit sink = newResumableConduit conduit =$++ sink

-- | Continue using a conduit after '=$+'.
(=$++) :: Monad m
       => ResumableConduit a m b
       -> Sink b m r
       -> Sink a m (ResumableConduit a m b, r)
(=$++) (ResumableConduit conduit0 final0) (ConduitM sink0) =
    ConduitM $ goSink final0 conduit0 sink0
  where
    goSink final conduit sink =
        case sink of
            HaveOutput _ _ o  -> absurd o
            NeedInput rp rc   -> goConduit rp rc final conduit
            Done r            -> Done (ResumableConduit conduit final, r)
            PipeM mp          -> PipeM (liftM recurse mp)
            Leftover sink' o  -> goSink final (HaveOutput conduit final o) sink'
      where
        recurse = goSink final conduit

    goConduit rp rc final conduit =
        case conduit of
            HaveOutput conduit' final' o -> goSink final' conduit' (rp o)
            NeedInput left' _lc -> NeedInput (recurse . left')
                                             (goSink final conduit . rc)
               -- Forward EOF to sink, but leave the conduit alone
               -- so it accepts input from the next source.
            Done r              -> goSink (return ()) (Done r) (rc r)
            PipeM mp            -> PipeM (liftM recurse mp)
            Leftover conduit' i -> Leftover (recurse conduit') i
      where
        recurse = goConduit rp rc final

-- | Finalize a 'ResumableConduit' by using it one more time.  It will be
-- closed when the sink finishes.
(=$+-) :: Monad m
       => ResumableConduit a m b
       -> Sink b m r
       -> Sink a m r
(=$+-) rconduit sink = do
    (ResumableConduit _ final, res) <- rconduit =$++ sink
    lift final
    return res
