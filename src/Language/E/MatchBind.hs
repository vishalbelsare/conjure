{-# LANGUAGE QuasiQuotes, ViewPatterns, OverloadedStrings #-}

module Language.E.MatchBind ( patternMatch, patternBind ) where

import Conjure.Prelude
import Stuff.MetaVariable
import Language.E.Definition
import Language.E.CompE
import Language.E.Pretty
import Language.E.Parser

import qualified Data.Text as T


-- returns a pair, first is True if patter matching succeeds
-- second is the new bindings generated by a successful match
-- these new binders are also in the state, one doesn't need to add them again.
-- useful for passing the bindings through scopes
patternMatch :: MonadConjure m => E -> E -> m (Bool, [Binder])
patternMatch pattern actual = do
    bs1 <- gets binders
    flag <- core pattern actual
    if flag
        then mkLog "patternMatch-success" $ vcat [pretty pattern, pretty actual]
        else mkLog "patternMatch-fail"    $ vcat [pretty pattern, pretty actual]
    bs2 <- gets binders
    return (flag, reverse $ drop (length bs1) $ reverse bs2 )
    where
        core [xMatch| [] := type.unknown |] y = do
            mkLog "patternMatch.core" $ vcat ["type.unknown", "~~", pretty y]
            return True
        core (Prim x) (Prim y) =
            if x == y
                then do
                    mkLog "patternMatch.core" $ vcat [ "same literal"
                                                     , pretty x
                                                     , "~~"
                                                     , pretty y
                                                     ]
                    return True
                else do
                    mkLog "patternMatch.core" $ vcat [ "literals not equal"
                                                     , pretty x
                                                     , "~~"
                                                     , pretty y
                                                     ]
                    return False
        core p _ | unnamedMV p =
            return True
        core p x | Just nm <- namedMV p = do
            addMetaVar nm x
            return True
        core [xMatch| xs := attrCollection |]
             [xMatch| ys := attrCollection |]
            = do
                let dontcare    = [xMake| attribute.dontCare := [] |]
                let xs'       = filter (/= dontcare) xs
                let hasDontcare = xs /= xs'
                if not hasDontcare
                    then do
                        let xsOrdered = sortNub xs'
                        let ysOrdered = sortNub ys
                        core [xMake| nowOrdered := xsOrdered |]
                             [xMake| nowOrdered := ysOrdered |]
                    else do
                        let foo _ [] = return False
                            foo j (i:is) = do
                                b <- core j i
                                if b then return True else foo j is
                        bs <- forM xs' $ \ x -> foo x ys
                        return $ and bs
        core _x@(Tagged xTag xArgs) _y@(Tagged yTag yArgs) =
            case (xTag == yTag, length xArgs == length yArgs) of
                (True, True) -> do
                    -- mkLog "patternMatch.core" $ "same tree label & equal number of subtrees. great" <+> pretty xTag
                    bs <- zipWithM core xArgs yArgs
                    if and bs
                        then
                            -- mkLog "patternMatch.core" $ vcat [ "all subtrees matched fine"
                            --                                  , pretty _x
                            --                                  , "~~"
                            --                                  , pretty _y
                            --                                  ]
                            return True
                        else do
                            mkLog "patternMatch.core" $ vcat [ "some subtrees didn't match"
                                                             , pretty _x
                                                             , "~~"
                                                             , pretty _y
                                                             ]
                            return False
                (False, _) -> do
                    mkLog "patternMatch.core" $ vcat [ "different tree labels"
                                                     , pretty xTag
                                                     , "~~"
                                                     , pretty yTag
                                                     ]
                    return False
                (_, False) -> do
                    mkLog "patternMatch.core" $ vcat [ "different number of subtrees"
                                                     , pretty _x
                                                     , "~~"
                                                     , pretty _y
                                                     ]
                    return False
        core _ _ =
            -- mkLog "patternMatch.core" $ vcat [ "this just fails"
            --                                  , pretty x
            --                                  , "~~"
            --                                  , pretty y
            --                                  ]
            return False


-- if this returns nothing, that means there is some unbound reference.
patternBind :: MonadConjure m => E -> MaybeT m E
patternBind x | Just nm <- namedMV x = do
    res <- lookupMetaVar nm
    patternBind res
patternBind (Tagged xTag xArgs) = Tagged xTag <$> mapM patternBind xArgs
patternBind x = return x


_testMatch :: String -> String -> IO ()
_testMatch patternText actualText = do
    pattern <- lexAndParseIO (inCompleteFile parseExpr) (T.pack patternText)
    actual  <- lexAndParseIO (inCompleteFile parseExpr) (T.pack actualText)
    (handleInIOSingle <=< runCompEIOSingle "testMatch") $ do
        (flag, _) <- patternMatch pattern actual
        bs        <- gets binders
        forM_ bs $ \ (Binder nm val) -> liftIO $ do
            putStr $ T.unpack nm
            putStr " : "
            putStrLn $ renderNormal val
        liftIO . putStrLn $
            if flag
                then "Matched."
                else "Not matched."

