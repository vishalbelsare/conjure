{-# LANGUAGE QuasiQuotes #-}

module Conjure.Process.Streamlining
    ( streamlining
    , streamliningToStdout
    ) where

import Conjure.Prelude
import Conjure.Language
import Conjure.Language.TypeOf ( typeOf )
import Conjure.Compute.DomainOf ( domainOf )


streamliningToStdout :: (MonadFail m, MonadLog m, MonadUserError m, NameGen m, MonadIO m) => Model -> m ()
streamliningToStdout model = do
    let
        whitespace '\t' = ' '
        whitespace '\n' = ' '
        whitespace ch   = ch

        showStr = pretty . show
        
    streamliners <- streamlining model

    liftIO $ print $ prettyList prBraces ","
        [ (showStr $ show i) <> ":" <+> (showStr $ map whitespace $ show $ pretty cons)
        | (i, cons) <- zip allNats streamliners
        ]


streamlining :: (MonadFail m, MonadLog m, MonadUserError m, NameGen m) => Model -> m [Expression]
streamlining model = do
    concatForM (mStatements model) $ \ statement ->
        case statement of
            Declaration (FindOrGiven Find nm domain) -> do
                let ref = Reference nm (Just (DeclNoRepr Find nm domain NoRegion))
                streamliners <- streamlinersForSingleVariable ref
                -- traceM $ show $ vcat [ "Streamliners for --" <+> pretty statement
                --                      , vcat [ nest 4 (pretty s) | s <- streamliners ]
                --                      ]
                return streamliners
            _ -> return []


type Streamliner = [Expression]

type StreamlinerGen m = Expression -> m Streamliner


-- given a reference to a top level variable, produce a list of all applicable streamliners
streamlinersForSingleVariable :: (MonadFail m, NameGen m) => StreamlinerGen m
streamlinersForSingleVariable x = concatMapM ($ x)
    [ intOdd
    , intEven
    , intLowerHalf
    , intUpperHalf

    , matrixAll streamlinersForSingleVariable
    , matrixHalf streamlinersForSingleVariable
    , matrixMost streamlinersForSingleVariable
    , matrixApproxHalf streamlinersForSingleVariable

    , setAll streamlinersForSingleVariable
    , setHalf streamlinersForSingleVariable
    , setMost streamlinersForSingleVariable
    , setApproxHalf streamlinersForSingleVariable

    , monotonicallyIncreasing
    , monotonicallyDecreasing
    , smallestFirst
    , largestFirst
    , commutative
    , nonCommutative
    , associative
    , onRange streamlinersForSingleVariable
    , onDefined streamlinersForSingleVariable
    -- , diagonal streamlinersForSingleVariable
    -- , prefix streamlinersForSingleVariable
    -- , postfix streamlinersForSingleVariable

    , parts streamlinersForSingleVariable
    , quasiRegular

    ]


------------------------------------------------------------------------------
-- Integers
------------------------------------------------------------------------------


-- given an integer expression (which can be a reference to a decision variable),
-- generate a constraint forcing it to be odd
intOdd :: (MonadFail m, NameGen m) => StreamlinerGen m
intOdd x = do
    ty <- typeOf x
    if typeUnify ty TypeInt
        then return $ return [essence| &x % 2 = 1 |]
        else return []


intEven :: MonadFail m => StreamlinerGen m
intEven x = do
    ty <- typeOf x
    if typeUnify ty TypeInt
        then return $ return [essence| &x % 2 = 0 |]
        else return []


intLowerHalf :: (MonadFail m, NameGen m) => StreamlinerGen m
intLowerHalf x = do
    ty <- typeOf x
    dom <- domainOf x
    case dom of
        DomainInt [RangeBounded _lower upper] -> do
            -- traceM $ show $ "DomainInt " <+> pretty (lower, upper)
            if typeUnify ty TypeInt
                then return $ return [essence| &x < 1 + (&upper -1) /2 |]
                else return []
        _ -> return []


intUpperHalf :: (MonadFail m, NameGen m) => StreamlinerGen m
intUpperHalf x = do
    ty <- typeOf x
    dom <- domainOf x
    case dom of
        DomainInt [RangeBounded _lower upper] -> do
            -- traceM $ show $ "DomainInt " <+> pretty (lower, upper)
            if typeUnify ty TypeInt
                then return $ return [essence| &x > 1 + (&upper -1) /2 |]
                else return []
        _ -> return []


------------------------------------------------------------------------------
-- Matrices
------------------------------------------------------------------------------


matrixAll :: (MonadFail m, NameGen m) => StreamlinerGen m -> StreamlinerGen m
matrixAll innerStreamliner x = do
    dom <- domainOf x
    case dom of
        DomainMatrix indexDom innerDom -> do
            nm <- nextName "q"
            -- traceM $ show $ "matrixAll nm" <+> pretty nm
            let pat = Single nm
                ref = Reference nm (Just (DeclNoRepr Find nm innerDom NoRegion))
                
                liftMatrix (Reference n _) | n == nm = [essence| &x[&ref] |]
                liftMatrix p = p

            innerConstraints <- transformBi liftMatrix <$> innerStreamliner ref
            -- traceM $ show $ "maybeInnerConstraint" <+> vcat (map pretty innerConstraints)
            forM innerConstraints $ \ innerConstraint ->
                    return [essence| forAll &pat : &indexDom . &innerConstraint |]
        _ -> return []


matrixMost :: (MonadFail m, NameGen m) => StreamlinerGen m -> StreamlinerGen m
matrixMost innerStreamliner x = do
    dom <- domainOf x
    case dom of
        DomainMatrix indexDom innerDom -> do
            nm <- nextName "q"
            let pat = Single nm
                ref = Reference nm (Just (DeclNoRepr Find nm innerDom NoRegion))
                
                liftMatrix (Reference n _) | n == nm = [essence| &x[&ref] |]
                liftMatrix p = p

            innerConstraints <- transformBi liftMatrix <$> innerStreamliner ref
            forM innerConstraints $ \ innerConstraint ->
                return [essence| 1 >= sum &pat : &indexDom . toInt(&innerConstraint) |]
        _ -> return []


matrixHalf :: (MonadFail m, NameGen m) => StreamlinerGen m -> StreamlinerGen m
matrixHalf innerStreamliner x = do
    dom <- domainOf x
    case dom of
        DomainMatrix indexDom innerDom -> do
            let size = [essence| |`&indexDom`| |]
            nm <- nextName "q"
            let pat = Single nm
                ref = Reference nm (Just (DeclNoRepr Find nm innerDom NoRegion))
                
                liftMatrix (Reference n _) | n == nm = [essence| &x[&ref] |]
                liftMatrix p = p

            innerConstraints <- transformBi liftMatrix <$> innerStreamliner ref
            forM innerConstraints $ \ innerConstraint ->
                    return [essence| &size / 2 = (sum &pat : &indexDom . toInt(&innerConstraint)) |]
        _ -> return []


matrixApproxHalf :: (MonadFail m, NameGen m) => StreamlinerGen m -> StreamlinerGen m
matrixApproxHalf innerStreamliner x = do
    dom <- domainOf x
    case dom of
        DomainMatrix indexDom innerDom -> do
            let size = [essence| |`&indexDom`| |]
            nm <- nextName "q"
            let pat = Single nm
                ref = Reference nm (Just (DeclNoRepr Find nm innerDom NoRegion))
                
                liftMatrix (Reference n _) | n == nm = [essence| &x[&ref] |]
                liftMatrix p = p

            innerConstraints <- transformBi liftMatrix <$> innerStreamliner ref
            forM innerConstraints $ \ innerConstraint ->
                return [essence|
                    (&size/2) + 1 >= (sum &pat : &indexDom . toInt(&innerConstraint)) /\
                    (&size/2 -1) <= (sum &pat : &indexDom . toInt(&innerConstraint))
                |]
        _ -> return []


------------------------------------------------------------------------------
-- Sets and MSets
------------------------------------------------------------------------------


setAll :: (MonadFail m, NameGen m) => StreamlinerGen m -> StreamlinerGen m
setAll innerStreamliner x = do
    dom <- domainOf x
    let minnerDom =
            case dom of
                DomainSet _ _ innerDom -> Just innerDom
                DomainMSet _ _ innerDom -> Just innerDom
                _ -> Nothing
    case minnerDom of
        Just innerDom -> do
            nm <- nextName "q"
            -- traceM $ show $ "setAll nm" <+> pretty nm
            let pat = Single nm
                ref = Reference nm (Just (DeclNoRepr Find nm innerDom NoRegion))
            innerConstraints <- innerStreamliner ref
            -- traceM $ show $ "maybeInnerConstraint" <+> vcat (map pretty innerConstraints)
            forM innerConstraints $ \ innerConstraint ->
                    return [essence| forAll &pat in &x . &innerConstraint |]
        _ -> return []


setMost :: (MonadFail m, NameGen m) => StreamlinerGen m -> StreamlinerGen m
setMost innerStreamliner x = do
    dom <- domainOf x
    let minnerDom =
            case dom of
                DomainSet _ _ innerDom -> Just innerDom
                DomainMSet _ _ innerDom -> Just innerDom
                _ -> Nothing
    case minnerDom of
        Just innerDom -> do
            nm <- nextName "q"
            let pat = Single nm
                ref = Reference nm (Just (DeclNoRepr Find nm innerDom NoRegion))
            innerConstraints <- innerStreamliner ref
            forM innerConstraints $ \ innerConstraint ->
                return [essence| 1 >= sum &pat in &x . toInt(&innerConstraint) |]
        _ -> return []


setHalf :: (MonadFail m, NameGen m) => StreamlinerGen m -> StreamlinerGen m
setHalf innerStreamliner x = do
    dom <- domainOf x
    let minnerDom =
            case dom of
                DomainSet _ _ innerDom -> Just innerDom
                DomainMSet _ _ innerDom -> Just innerDom
                _ -> Nothing
    case minnerDom of
        Just innerDom -> do
            let size = [essence| |&x| |]
            nm <- nextName "q"
            let pat = Single nm
                ref = Reference nm (Just (DeclNoRepr Find nm innerDom NoRegion))
            innerConstraints <- innerStreamliner ref
            forM innerConstraints $ \ innerConstraint ->
                    return [essence| &size / 2 = (sum &pat in &x . toInt(&innerConstraint)) |]
        _ -> return []


setApproxHalf :: (MonadFail m, NameGen m) => StreamlinerGen m -> StreamlinerGen m
setApproxHalf innerStreamliner x = do
    dom <- domainOf x
    let minnerDom =
            case dom of
                DomainSet _ _ innerDom -> Just innerDom
                DomainMSet _ _ innerDom -> Just innerDom
                _ -> Nothing
    case minnerDom of
        Just innerDom -> do
            let size = [essence| |&x| |]
            nm <- nextName "q"
            let pat = Single nm
                ref = Reference nm (Just (DeclNoRepr Find nm innerDom NoRegion))
            innerConstraints <- innerStreamliner ref
            forM innerConstraints $ \ innerConstraint ->
                return [essence|
                    (&size/2) + 1 >= (sum &pat in &x . toInt(&innerConstraint)) /\
                    (&size/2 -1) <= (sum &pat in &x . toInt(&innerConstraint))
                |]
        _ -> return []


------------------------------------------------------------------------------
-- Functions
------------------------------------------------------------------------------


monotonicallyIncreasing :: (MonadFail m, NameGen m) => StreamlinerGen m
monotonicallyIncreasing x = do
    dom <- domainOf x
    -- traceM $ show $ "Monotonically Increasing"
    case dom of
        DomainFunction _ _attrs (DomainInt _) (DomainInt _)-> do
            (iPat, i) <- quantifiedVar
            (jPat, j) <- quantifiedVar
            return $ return [essence|
                forAll &iPat in defined(&x) .
                    forAll &jPat in defined(&x) .
                        &i < &j -> &x(&i) <= &x(&j)
            |]
        _ -> return []


monotonicallyDecreasing :: (MonadFail m, NameGen m) => StreamlinerGen m
monotonicallyDecreasing x = do
    dom <- domainOf x
    case dom of
        DomainFunction _ _attrs (DomainInt _) (DomainInt _) -> do
            -- traceM $ show $ "Monotonically Decreasing"
            (iPat, i) <- quantifiedVar
            (jPat, j) <- quantifiedVar
            return $ return [essence|
                forAll &iPat in defined(&x) .
                    forAll &jPat in defined(&x) .
                        &i < &j -> &x(&i) >= &x(&j)
            |]
        _ -> return []


smallestFirst :: (MonadFail m, NameGen m) => StreamlinerGen m
smallestFirst x = do
    dom <- domainOf x
    case dom of
         DomainFunction _ _attrs (DomainInt _) (DomainInt _) -> do
            -- traceM $ show $ "Smallest First"
            (ipat, i) <- quantifiedVar
            return $ return [essence|
                forAll &ipat in defined(&x) .
                    &x(min(defined(&x))) <= &x(&i)
            |]
         _ -> return []


largestFirst :: (MonadFail m, NameGen m) => StreamlinerGen m
largestFirst x = do
    dom <- domainOf x
    case dom of
         DomainFunction _ _attrs (DomainInt _) (DomainInt _) -> do
            -- traceM $ show $ "Largest First"
            (ipat, i) <- quantifiedVar
            return $ return [essence|
                forAll &ipat in defined(&x) .
                    &x(max(defined(&x))) >= &x(&i)
            |]
         _ -> return []


commutative :: (MonadFail m, NameGen m) => StreamlinerGen m
commutative x = do
    dom <- domainOf x
    case dom of
        DomainFunction () _ (DomainTuple [a, b]) c-> do
            if (a==b) && (b==c)
                then do
                    (ipat, i) <- quantifiedVar
                    (jpat, j) <- quantifiedVar
                    return $ return [essence|
                        forAll (&ipat,&jpat) in defined(&x) .
                            &x((&i,&j)) = &x((&j,&i))
                    |]
                else return []
        _ -> return []


nonCommutative :: (MonadFail m, NameGen m) => StreamlinerGen m
nonCommutative x = do
    dom <- domainOf x
    case dom of
        DomainFunction () _ (DomainTuple [a, b]) c-> do
            if (a==b) && (b==c)
                then do
                    (ipat, i) <- quantifiedVar
                    (jpat, j) <- quantifiedVar
                    return $ return [essence|
                        forAll (&ipat,&jpat) in defined(&x) .
                            &x((&i,&j)) != &x((&j,&i))
                    |]
                else return []
        _ -> return []


associative :: (MonadFail m, NameGen m) => StreamlinerGen m
associative x = do
    dom <- domainOf x
    case dom of
        DomainFunction () _ (DomainTuple [a, b]) c -> do
            if (a==b) && (b==c)
                then do
                    (ipat, i) <- quantifiedVar
                    (jpat, j) <- quantifiedVar
                    return $ return [essence|
                        forAll (&ipat,&jpat) in defined(&x) .
                            &x((&x(&i,&j), &j)) = &x((&i, &x(&i, &j)))
                    |]
                else return []
        _ -> return []


onRange :: (MonadFail m, NameGen m) => StreamlinerGen m -> StreamlinerGen m
onRange innerStreamliner x = do
    -- traceM $ show $ "onRange" <+> pretty x
    dom <- domainOf x
    -- traceM $ show $ "onRange dom" <+> pretty dom
    case dom of
        DomainFunction () _ _innerDomFr innerDomTo -> do

            let rangeSetDomain = DomainSet () def innerDomTo

            nm <- nextName "q"
            let ref = Reference nm (Just (DeclNoRepr Find nm rangeSetDomain NoRegion))
            innerConstraints <- innerStreamliner ref

            let
                replaceWithRangeOfX (Reference n _) | n == nm = [essence| range(&x) |]
                replaceWithRangeOfX p = p

            -- traceM $ show $ "innerConstraints 1" <+> vcat (map pretty innerConstraints)
            -- traceM $ show $ "innerConstraints 2" <+> vcat (map pretty (transformBi replaceWithRangeOfX innerConstraints))

            return (transformBi replaceWithRangeOfX innerConstraints)

        _ -> return []


onDefined :: (MonadFail m, NameGen m) => StreamlinerGen m -> StreamlinerGen m
onDefined innerStreamliner x = do
    -- traceM $ show $ "Defined" <+> pretty x
    dom <- domainOf x
    -- traceM $ show $ "Defined dom" <+> pretty dom
    -- So we get the range and then we apply and then apply the rule to the range of the function
    case dom of
        DomainFunction () _ innerDomFr _innerDomTo -> do

            let rangeSetDomain = DomainSet () def innerDomFr

            nm <- nextName "q"
            let ref = Reference nm (Just (DeclNoRepr Find nm rangeSetDomain NoRegion))
            innerConstraints <- innerStreamliner ref

            let
                replaceWithRangeOfX (Reference n _) | n == nm = [essence| defined(&x) |]
                replaceWithRangeOfX p = p

            -- traceM $ show $ "innerConstraints 1" <+> vcat (map pretty innerConstraints)
            -- traceM $ show $ "innerConstraints 2" <+> vcat (map pretty (transformBi replaceWithRangeOfX innerConstraints))

            return (transformBi replaceWithRangeOfX innerConstraints)

        _ -> return []


-- diagonal :: (MonadFail m, NameGen m) => StreamlinerGen m -> StreamlinerGen m
-- diagonal innerStreamliner x = do
--     traceM $ show $ "diagnoal" <+> pretty x
--     dom <- domainOf x
--     case dom of
--         DomainFunction () _ (DomainTuple [a, b]) domto-> do
--             case (a == b)  of
--                 True -> do
--                     nm <- nextname "fx"
--                     let auxfunction = domainfunction () def a domto
--                         ref =  reference nm (just (declnorepr find nm auxfunction noregion))

--                     i <- nextname "q"
--                     (ipat, i) <- quantifiedvar

--                     innerconstraints <- innerstreamliner ref
--                     return $ return [essence| find &ref: function &a --> &domto such that forall &ipat: &a. (&i, &i) in defined(&x) -> &ref(&i) = &x((&i,&i)),
--                                     forall &ipat: &a . &i in defined(&ref) -> &ref(&i) = &x((&i,&i)) |]
--                 False -> do
--                     return []
--         _ -> return []

-- 
-- prefix :: (MonadFail m, NameGen m) => StreamlinerGen m ->  StreamlinerGen m
-- prefix innerStreamliner x = do
--     traceM $ show $ "prefix"
--     dom <- domainOf x
--     case dom of
--         DomainFunction () _ (DomainInt [RangeBounded lb up]) innerDomTo -> do
--             case x of
--                 Reference nm (Just (DeclNoRepr Find _ domain NoRegion)) -> do

--                     innerConstraints <- innerStreamliner x

--                     let
--                         replaceWithRangeOfX (Reference n _) | n == nm = [essence| restrict(&x,`int(&lb..(&up-1))`) |]
--                         replaceWithRangeOfX p = p

--                 --  traceM $ show $ "innerConstraints 1" <+> vcat (map pretty innerConstraints)
--                 -- traceM $ show $ "innerConstraints 2" <+> vcat (map pretty (transformBi replaceWithRangeOfX innerConstraints))

--                     return (transformBi replaceWithRangeOfX innerConstraints)
--                 _ -> return []

--         _ -> return []
-- 

-- postfix :: (MonadFail m, NameGen m) => StreamlinerGen m ->  StreamlinerGen m
-- postfix innerStreamliner x = do
--     traceM $ show $ "postfix"
--     dom <- domainOf x
--     case dom of
--         DomainFunction () _ (DomainInt [RangeBounded lb up]) innerDomTo -> do
--             case x of
--                 Reference nm (Just (DeclNoRepr Find _ domain NoRegion)) -> do

--                     innerConstraints <- innerStreamliner x

--                     let
--                         replaceWithRangeOfX (Reference n _) | n == nm = [essence| restrict(&x,`int((&lb+1)..&up)`) |]
--                         replaceWithRangeOfX p = p

--                 --  traceM $ show $ "innerConstraints 1" <+> vcat (map pretty innerConstraints)
--                 -- traceM $ show $ "innerConstraints 2" <+> vcat (map pretty (transformBi replaceWithRangeOfX innerConstraints))

--                     return (transformBi replaceWithRangeOfX innerConstraints)
--                 _ -> return []

--         _ -> return []


------------------------------------------------------------------------------
-- Partitions
------------------------------------------------------------------------------


parts :: (MonadFail m, NameGen m) => StreamlinerGen m -> StreamlinerGen m
parts innerStreamliner x = do
    dom <- domainOf x
    case dom of
        DomainPartition _ _ partitionDomain -> do
            -- traceM $ show $ "partition"
            nm <- nextName "q"
            let setDomain = DomainSet () def (DomainSet () def partitionDomain)
                ref =  Reference nm (Just (DeclNoRepr Find nm setDomain NoRegion))

            innerConstraints <- innerStreamliner ref


            let
                replaceWithRangeOfX (Reference n _) | n == nm = [essence| parts(&x) |]
                replaceWithRangeOfX p = p

            return (transformBi replaceWithRangeOfX innerConstraints)

        _ -> return []


quasiRegular :: (MonadFail m, NameGen m) => StreamlinerGen m
quasiRegular x = do
    dom <- domainOf x
    case dom of
        DomainPartition{} -> do
            return $ return [essence|
                minPartSize(&x, |participants(&x)| / |parts(&x)| - 1) /\
                maxPartSize(&x, |participants(&x)|/ |parts(&x)| + 1)
            |]
        _ -> return []