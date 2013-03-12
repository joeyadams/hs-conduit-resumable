{-# LANGUAGE OverloadedStrings #-}
import Test.Hspec
import Data.Conduit
import Data.Conduit.List (consume, sourceList, sourceNull)
import qualified Data.Conduit.List as CL
import Data.Conduit.Resumable

import Control.Monad.IO.Class
import Data.Char (isSpace)
import Data.IORef

main :: IO ()
main = hspec $ do
    describe "resumable sources" $ do
        let testFinalizeWith :: (ResumableSource IO Char -> Sink Char IO () -> IO ()) -> IO ()
            testFinalizeWith finalize = do
                tallies <- newIORef (0 :: Int, 0 :: Int, 0 :: Int)
                let src = do
                        yieldOr 'a' $ modifyIORef tallies $ \(a,b,c) -> (a+1, b, c)
                        yieldOr 'b' $ modifyIORef tallies $ \(a,b,c) -> (a, b+1, c)
                        liftIO      $ modifyIORef tallies $ \(a,b,c) -> (a, b, c+1)

                (rsrc1, ()) <- src $$+ return ()
                rsrc1 `finalize` return ()
                (0,0,0) <- readIORef tallies

                (rsrc2, ()) <- src $$+ return ()
                rsrc2 `finalize` do
                    Just 'a' <- await
                    return ()
                (1,0,0) <- readIORef tallies

                (rsrc3, ()) <- src $$+ return ()
                rsrc3 `finalize` do
                    Just 'a' <- await
                    Just 'b' <- await
                    return ()
                (1,1,0) <- readIORef tallies

                -- Finalizer is not run when source runs to completion.
                (rsrc4, ()) <- src $$+ return ()
                rsrc4 `finalize` do
                    Just 'a' <- await
                    Just 'b' <- await
                    Nothing  <- await
                    return ()
                (1,1,1) <- readIORef tallies

                return ()

        it "$$+- finalizes properly" $ do
            testFinalizeWith ($$+-)

        it "finishResumableSource finalizes properly" $ do
            testFinalizeWith $ \rsrc sink -> finishResumableSource rsrc $$ sink

    describe "resumable conduits" $ do
        let c0 = CL.groupBy (==) :: Conduit Int IO [Int]

        it "doesn't see EOF until termination" $ do
            (c1, [[1,1],[2,2]]) <- CL.sourceList [1,1,2,2,3,3] $$ c0 =$+ CL.consume
            [[3,3]] <- CL.sourceList [] $$ c1 =$+- CL.consume
            return ()

        it "empty case" $ do
            (c1, []) <- sourceNull $$ c0 =$+ CL.consume
            [] <- sourceNull $$ c1 =$+- CL.consume
            return ()

        it "doesn't see EOF between incremental feeds" $ do
            (c1, [[1,1],[2,2]]) <- sourceList [1,1,2,2,3,3] $$ c0 =$+ consume
            (c2, []) <- sourceList [3,3,3] $$ c1 =$++ consume
            (c3, [[3,3,3,3,3],[4]]) <- sourceList [4,5] $$ c2 =$++ consume
            [[5]] <- sourceList [] $$ c3 =$+- consume
            return ()

        it "sink leftovers are returned to the conduit" $ do
            -- Warning: since the conduit does not consume the input list,
            -- the sourceList data is discarded.  This means we can't treat
            -- multiple source feeds as concatenation of the sources.
            (c1, ()) <- sourceList [1,2,2,3,3,3] $$ c0 =$+ leftover [4,4,4,4]

            (c2, ()) <- sourceList [5] $$ c1 =$++ do
                Just [4,4,4,4] <- await
                Nothing <- await
                leftover [5]
            [[5],[5], [3]] <- sourceList [3] $$ c2 =$+- consume
                -- Note: this output is inconsistent for the groupBy conduit.
                -- It's the fault of the consumer for producing a 'leftover'
                -- it wasn't given.
            return ()

        it' "can be used within a sink as a temporary filter" $ do
            c5 <- sourceList "The quick brown fox jumps over a lazy dog" $$ do
                (c2, ["The", "quick"]) <- conduitWords =$+ CL.take 2
                (c3, []) <- c2 =$++ CL.take 0
                (c4, ["brown", "fox"]) <- c3 =$++ CL.take 2
                "jumps ov" <- CL.take 8
                (c5, ["er", "a", "lazy"]) <- c4 =$++ CL.consume
                return c5

            -- That conduit can then be returned from the sink and used in
            -- another sink (without forgetting about what it consumed before).
            sourceList "One two three" $$ do
                (c6, ["dogOne", "two"]) <- c5 =$++ CL.consume
                ["three"] <- c6 =$+- CL.consume
                return ()

        -- TODO: test -$+ inside of a conduit, rather than just a sink.

    describe "resumable sink" $ do
      it "behaves like normal conduit when -+$$ used immediately" $ do
        r <- runResourceT $
               (sourceList ["hello", "world"]) -+$$ (newResumableSink consume)
        r `shouldBe` ["hello", "world" :: String]

      it "sink can be resumed" $ do
        r <- runResourceT $ do
               Left r1 <- ((sourceList ["hello", "world"]) +$$ consume)
               (sourceList ["hello", "world"]) -+$$ r1
        r `shouldBe` ["hello", "world", "hello", "world" :: String]

      it "does correct cleanup" $ do
        s <- newIORef (0 :: Int, 0 :: Int, 0 :: Int)
        r <- runResourceT $ do
               Left r1 <-
                 ((addCleanup (const . liftIO $ modifyIORef s (\(a,b,c) -> (a + 1, b, c))) (sourceList ["hello", "world"])) +$$
                            addCleanup (const . liftIO $ modifyIORef s (\(a,b,c) -> (a,b,c+1))) (consume))
               ((addCleanup (const . liftIO $ modifyIORef s (\(a, b, c) -> (a, b + 1, c))) (sourceList ["hello", "world"]))) -+$$ r1
        r `shouldBe` ["hello", "world", "hello", "world" :: String]
        sfinal <- readIORef s
        sfinal `shouldBe` (1, 1, 1)

it' :: String -> IO () -> Spec
it' = it

conduitWords :: Monad m => Conduit Char m String
conduitWords = leadingSpace
  where
    leadingSpace = do
        m <- await
        case m of
            Nothing -> return ()
            Just c
              | isSpace c -> leadingSpace
              | otherwise -> word [c]

    word cs = do
        m <- await
        case m of
            Nothing -> yield (reverse cs)
            Just c
              | isSpace c -> yield (reverse cs) >> leadingSpace
              | otherwise -> word (c:cs)
