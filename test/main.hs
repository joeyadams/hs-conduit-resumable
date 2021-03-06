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

    describe "resumable conduits" $ do
        let c0 = CL.groupBy (==) :: Conduit Int IO [Int]

        it "doesn't see EOF until termination" $ do
            (c1, a) <- CL.sourceList [1,1,2,2,3,3] $$ c0 =$+ CL.consume
            a `shouldBe` [[1,1],[2,2]]
            b <- CL.sourceList [] $$ c1 =$+- CL.consume
            b `shouldBe` [[3,3]]
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

        it' "finalizing conduit without consuming all output calls finalizer" $ do
            fin <- newIORef []
            let takeFin = liftIO $ do
                    xs <- readIORef fin
                    writeIORef fin []
                    return $! reverse xs

            let c1 = do
                    m <- await
                    case m of
                        Nothing -> do
                            yieldOr '1' (modifyIORef fin ('1':))
                            yieldOr '2' (modifyIORef fin ('2':))
                            yieldOr '3' (modifyIORef fin ('3':))
                            liftIO $ modifyIORef fin ('4':)
                        Just x -> do
                            yieldOr x (modifyIORef fin ('x':))
                            yieldOr x (modifyIORef fin ('y':))
                            c1

            sourceList "abc" $$ do
                (c2, ()) <- c1 =$+ do
                    Just 'a' <- await
                    Just 'a' <- await
                    Just 'b' <- await
                    return ()
                [] <- takeFin -- conduit still running, so shouldn't be finalized

                (c3, ()) <- c2 =$++ do
                    Just 'b' <- await
                    return ()
                [] <- takeFin

                (c4, ()) <- c3 =$++ do
                    Just 'c' <- await
                    Just 'c' <- await
                    Nothing <- await  -- EOF skipped conduit
                    return ()
                [] <- takeFin

                c4 =$+- do
                    Just '1' <- await
                    Just '2' <- await
                    return ()
                ['2'] <- takeFin

                return ()

            -- Test non-resumed conduits, too.
            sourceList "abc" $$ do
                c1 =$ do
                    Just 'a' <- await
                    Just 'a' <- await
                    Just 'b' <- await
                    return ()
                ['x'] <- takeFin

                c1 =$ return ()
                [] <- takeFin

                c1 =$ do
                    Just 'c' <- await
                    Just 'c' <- await
                    return ()
                ['y'] <- takeFin

                return ()

    describe "resumable sink" $ do
      it "sink can be resumed" $ do
        r <- runResourceT $ do
               Left r1 <- ((sourceList ["hello", "world"]) +$$ consume)
               (sourceList ["hello", "world"]) $$ r1
        r `shouldBe` ["hello", "world", "hello", "world" :: String]

      it "does correct cleanup" $ do
        s <- newIORef (0 :: Int, 0 :: Int, 0 :: Int)
        r <- runResourceT $ do
               Left r1 <-
                 ((addCleanup (const . liftIO $ modifyIORef s (\(a,b,c) -> (a + 1, b, c))) (sourceList ["hello", "world"])) +$$
                            addCleanup (const . liftIO $ modifyIORef s (\(a,b,c) -> (a,b,c+1))) (consume))
               ((addCleanup (const . liftIO $ modifyIORef s (\(a, b, c) -> (a, b + 1, c))) (sourceList ["hello", "world"]))) $$ r1
        r `shouldBe` ["hello", "world", "hello", "world" :: String]
        sfinal <- readIORef s
        sfinal `shouldBe` (1, 1, 1)

      it "+$$+ and company" $ do
        ref <- newIORef ([] :: [String])
        let takeRef = liftIO $ do
                xs <- readIORef ref
                writeIORef ref []
                return $! reverse xs
        let src0  = mapM_ yield "Hello world"
            sink0 = conduitWords =$ CL.mapM_ (modifyIORef ref . (:))
        (src1, Left sink1) <- src0 +$$+ sink0
        ["Hello"] <- takeRef  -- "world" not generated yet because sink
                              -- did not see EOF.

        Nothing <- src1 $$+- await

        (src2, Left sink2) <- (mapM_ yield "ly folk") +$$+ sink1
        ["worldly"] <- takeRef  -- See, the world didn't end, it was just cut
                                -- apart due to some boundary issue.

        (src3, Left sink3) <- src2 +$$++ sink2
        [] <- takeRef -- No progress; same source and sink.

        Left sink4 <- src3 +$$+- sink3
        [] <- takeRef -- Again, the sink did not see EOF yet, so doesn't know
                      -- if the word will have more letters.

        return () $$ sink4
        ["folk"] <- takeRef

        return ()


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
