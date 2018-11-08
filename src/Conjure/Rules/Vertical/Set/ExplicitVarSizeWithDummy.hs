{-# LANGUAGE QuasiQuotes #-}

module Conjure.Rules.Vertical.Set.ExplicitVarSizeWithDummy where

import Conjure.Rules.Import


rule_Comprehension :: Rule
rule_Comprehension = "set-comprehension{ExplicitVarSizeWithDummy}" `namedRule` theRule where
    theRule (Comprehension body gensOrConds) = do
        (gocBefore, (pat, s), gocAfter) <- matchFirst gensOrConds $ \ goc -> case goc of
            Generator (GenInExpr pat@Single{} s) -> return (pat, matchDefs [opToSet,opToMSet] s)
            _ -> na "rule_Comprehension"
        TypeSet{}                    <- typeOf s
        Set_ExplicitVarSizeWithDummy <- representationOf s
        [values]                     <- downX1 s
        DomainMatrix index inner     <- domainOf values
        let dummy = [essence| max(`&inner`) |]
        let upd val old = lambdaToFunction pat old val
        return
            ( "Vertical rule for set-comprehension, ExplicitVarSizeWithDummy representation"
            , do
                (jPat, j) <- quantifiedVar
                let val = [essence| &values[&j] |]
                return $ Comprehension (upd val body)
                        $  gocBefore
                        ++ [ Generator (GenDomainNoRepr jPat index)
                           , Condition [essence| &val != &dummy |]
                           ]
                        ++ transformBi (upd val) gocAfter
               )
    theRule _ = na "rule_Comprehension"


rule_PowerSet_Comprehension :: Rule
rule_PowerSet_Comprehension = "set-powerSet-comprehension{ExplicitVarSizeWithDummy}" `namedRule` theRule where
    theRule (Comprehension body gensOrConds) = do
        (gocBefore, (setPat, setPatNum, expr), gocAfter) <- matchFirst gensOrConds $ \ goc -> case goc of
            Generator (GenInExpr setPat@(AbsPatSet pats) expr) -> return (setPat, length pats, expr)
            _ -> na "rule_PowerSet_Comprehension"
        s                            <- match opPowerSet expr
        TypeSet{}                    <- typeOf s
        Set_ExplicitVarSizeWithDummy <- representationOf s
        [values]                     <- downX1 s
        DomainMatrix index inner     <- domainOf values
        let dummy = [essence| max(`&inner`) |]
        let upd val old = lambdaToFunction setPat old val
        return
            ( "Vertical rule for set-comprehension, ExplicitVarSizeWithDummy representation"
            , do
                outPats <- replicateM setPatNum quantifiedVar
                let val = AbstractLiteral $ AbsLitSet [ [essence| &values[&j] |] | (_,j) <- outPats ]
                return $ Comprehension (upd val body) $ concat
                        [ gocBefore
                        , concat
                            [ [ Generator (GenDomainNoRepr pat index)
                              , Condition [essence| &values[&patX] != &dummy |]
                              ]
                            | (pat,patX) <- take 1 outPats
                            ]
                        , concat
                            [ [ Generator (GenDomainNoRepr pat index)
                              , Condition [essence| &patX > &beforeX |]
                              , Condition [essence| &values[&patX] != &dummy |]
                              ]
                            | ((_, beforeX), (pat, patX)) <- zip outPats (tail outPats)
                            ]
                        , transformBi (upd val) gocAfter
                        ]
            )
    theRule _ = na "rule_PowerSet_Comprehension"


rule_frameUpdate_propagator :: Rule
rule_frameUpdate_propagator = "set-frameUpdate{ExplicitVarSizeWithDummy}" `namedRule` theRule where
    theRule p = do
        (source, target, sourceFocus, targetFocus, cons) <- match opFrameUpdate p

        TypeSet{}                            <- typeOf source
        Set_ExplicitVarSizeWithDummy         <- representationOf source
        [sourceValues]                       <- downX1 source
        DomainMatrix sourceIndex sourceInner <- domainOf sourceValues
        let sourceDummy = [essence| max(`&sourceInner`) |]

        TypeSet{}                            <- typeOf target
        Set_ExplicitVarSizeWithDummy         <- representationOf target
        [targetValues]                       <- downX1 target
        DomainMatrix targetIndex targetInner <- domainOf targetValues
        let targetDummy = [essence| max(`&targetInner`) |]

        return
            ( "Vertical rule for set-frameUpdate, ExplicitVarSizeWithDummy representation"
            , do

                sourceFocusNames <- forM sourceFocus $ \ x -> do
                    (auxName, aux) <- auxiliaryVar
                    return (x, auxName, aux, sourceIndex)

                targetFocusNames <- forM targetFocus $ \ x -> do
                    (auxName, aux) <- auxiliaryVar
                    return (x, auxName, aux, targetIndex)

                let
                    sourceFocusVars :: Expression
                    sourceFocusVars = fromList $ [auxVar | (_,_,auxVar,_) <- sourceFocusNames]

                    targetFocusVars :: Expression
                    targetFocusVars = fromList $ [auxVar | (_,_,auxVar,_) <- targetFocusNames]

                    consOut :: Expression
                    consOut = flip transform cons $ \ h -> case h of
                        Reference nm (Just FrameUpdateVar{}) ->
                            case ( [auxVar | (userName, _, auxVar, _) <- sourceFocusNames, userName == nm]
                                 , [auxVar | (userName, _, auxVar, _) <- targetFocusNames, userName == nm] ) of
                                ([auxVar], _) -> [essence| &sourceValues[&auxVar] |]
                                (_, [auxVar]) -> [essence| &targetValues[&auxVar] |]
                                _             -> h
                        _ -> h

                    frameUpdateOut :: Expression
                    frameUpdateOut = [essence| frameUpdate(&sourceValues, &targetValues, &sourceFocusVars, &targetFocusVars) |]

                    nbSources = fromInt $ genericLength sourceFocus
                    nbTargets = fromInt $ genericLength targetFocus
                    impliedSize =
                        [essence| |&target| = |&source| + (&nbTargets - &nbSources) |]

                    out = WithLocals
                        [essence| true |]
                        (AuxiliaryVars $
                            [ Declaration (FindOrGiven LocalFind auxName domain)
                            | (_userName, auxName, _auxVar, domain) <- sourceFocusNames
                            ] ++
                            [ Declaration (FindOrGiven LocalFind auxName domain)
                            | (_userName, auxName, _auxVar, domain) <- targetFocusNames
                            ] ++
                            [ SuchThat
                                [ make opAllDiff sourceFocusVars
                                , make opAnd     (fromList [ [essence| &auxVar != &sourceDummy |]
                                                           | (_,_,auxVar,_) <- sourceFocusNames ])

                                , make opAllDiff targetFocusVars
                                , make opAnd     (fromList [ [essence| &auxVar != &targetDummy |]
                                                           | (_,_,auxVar,_) <- targetFocusNames ])

                                , consOut
                                , frameUpdateOut
                                , impliedSize
                                ]
                            ])

                return out
            )


rule_frameUpdate_decomposition :: Rule
rule_frameUpdate_decomposition = "set-frameUpdate{ExplicitVarSizeWithDummy}" `namedRule` theRule where
    theRule p = do
        (old, new, oldFocus, newFocus, cons) <- match opFrameUpdate p

        TypeSet{}                      <- typeOf old
        Set_ExplicitVarSizeWithDummy   <- representationOf old
        [oldValues]                    <- downX1 old
        DomainMatrix oldIndex oldInner <- domainOf oldValues
        let oldDummy = [essence| max(`&oldInner`) |]

        TypeSet{}                      <- typeOf new
        Set_ExplicitVarSizeWithDummy   <- representationOf new
        [newValues]                    <- downX1 new
        DomainMatrix newIndex newInner <- domainOf newValues
        let newDummy = [essence| max(`&newInner`) |]

        return
            ( "Vertical rule for set-frameUpdate, ExplicitVarSizeWithDummy representation"
            , do

                focusNames_a <- forM oldFocus $ \ a -> do
                    (auxName, aux) <- auxiliaryVar
                    return (a, auxName, aux, oldIndex)

                focusNames_b <- forM newFocus $ \ b -> do
                    (auxName, aux) <- auxiliaryVar
                    return (b, auxName, aux, newIndex)

                let consOut = flip transform cons $ \ h -> case h of
                        Reference nm (Just FrameUpdateVar{}) ->
                            case ( [auxVar | (userName, _, auxVar, _) <- focusNames_a, userName == nm]
                                 , [auxVar | (userName, _, auxVar, _) <- focusNames_b, userName == nm] ) of
                                ([auxVar], _) -> [essence| &oldValues[&auxVar] |]
                                (_, [auxVar]) -> [essence| &newValues[&auxVar] |]
                                _             -> h
                        _ -> h

                (kPat, k) <- quantifiedVar
                (contiguousCountsPat, contiguousCounts) <- auxiliaryVar
                (offsetsPat, offsets) <- auxiliaryVar

                -- build contiguousCounts
                let
                    contiguousCountsCons =
                        let
                            is_a t = make opOr  $ fromList [ [essence| &t = &i |]
                                                           | (_, _, i, _) <- focusNames_a
                                                           ]

                            maxOldIndex = [essence| max(`&oldIndex`) |]
                            maxOldIndex_is_a = is_a maxOldIndex

                            maxOldIndexMinusK_is_a = is_a [essence| &maxOldIndex - &k |]

                        in
                            [essence|
                                (&contiguousCounts[&maxOldIndex] = toInt(&maxOldIndex_is_a)) /\
                                forAll &kPat : int(1..&maxOldIndex-1) .
                                    (&contiguousCounts[&maxOldIndex-&k] = 0 <-> ! &maxOldIndexMinusK_is_a) /\
                                    (&maxOldIndexMinusK_is_a -> &contiguousCounts[&maxOldIndex-&k] = &contiguousCounts[&maxOldIndex-(&k-1)] +1)
                            |]

                -- build offsets matrix
                let
                    buildOffSetsCons = 
                        let
                            is_b t = make opOr  $ fromList [ [essence| &t = &i |]
                                                           | (_, _, i, _) <- focusNames_b
                                                           ]

                            k_is_b = is_b k

                            one_is_b = is_b [essence| 1 |]

                            maxOldIndex = [essence| max(`&oldIndex`) |]

                        in
                            [essence|
                                (&offsets[1] = (0 - toInt(&one_is_b) + catchUndef(&contiguousCounts[1 - toInt(&one_is_b)], 0))) /\
                                forAll &kPat : int(2..&maxOldIndex) .
                                    &offsets[&k] = (&offsets[&k-1] - toInt(&k_is_b))
                                                + catchUndef(&contiguousCounts[(&offsets[&k-1] - toInt(&k_is_b)) + &k], 0)
                            |]

                let nbOlds = fromInt $ genericLength oldFocus
                let nbNews = fromInt $ genericLength newFocus

                -- keep everything out of focus unchanged
                let freezeFrameCons =
                        let
                            k_is_b = make opOr  $ fromList [ [essence| &k = &i |]
                                                           | (_, _, i, _) <- focusNames_b
                                                           ]
          
                            maxOldIndex = [essence| max(`&oldIndex`) |]
          
                        in
                            if length newFocus >= length oldFocus
                                then
                                    [essence|
                                        forAll &kPat : int(1..&maxOldIndex) .
                                            (! &k_is_b) -> &newValues[&k] = &oldValues[&k + &offsets[&k]]
                                    |]
                                else
                                    [essence|
                                        forAll &kPat : int(1..&maxOldIndex - (&nbOlds - &nbNews)) .
                                            (! &k_is_b) -> &newValues[&k] = &oldValues[&k + &offsets[&k]]
                                    |]
 
                let impliedSize =
                        [essence| |&new| = |&old| + (&nbNews - &nbOlds) |]

                let out = WithLocals
                        [essence| true |]
                        (AuxiliaryVars $
                            [ Declaration (FindOrGiven LocalFind auxName domain)
                            | (_userName, auxName, _auxVar, domain) <- focusNames_a
                            ] ++
                            [ Declaration (FindOrGiven LocalFind auxName domain)
                            | (_userName, auxName, _auxVar, domain) <- focusNames_b
                            ] ++
                            [ Declaration (FindOrGiven LocalFind contiguousCountsPat
                                    (DomainMatrix oldIndex
                                        (DomainInt AnyTag [RangeBounded
                                                        0
                                                        (fromInt $ genericLength focusNames_a)])))
                            , Declaration (FindOrGiven LocalFind offsetsPat
                                    (DomainMatrix oldIndex
                                        (DomainInt AnyTag [RangeBounded
                                                        (fromInt $ negate $ maximum [genericLength focusNames_a, genericLength focusNames_b])
                                                        (fromInt $          maximum [genericLength focusNames_a, genericLength focusNames_b])])))
                            ] ++
                            [ SuchThat
                                [ make opAllDiff (fromList [auxVar | (_,_,auxVar,_) <- focusNames_a])
                                , make opAnd     (fromList [ [essence| &oldValues[&auxVar] != &oldDummy |]
                                                           | (_,_,auxVar,_) <- focusNames_a ])

                                , make opAllDiff (fromList [auxVar | (_,_,auxVar,_) <- focusNames_b])
                                , make opAnd     (fromList [ [essence| &newValues[&auxVar] != &newDummy |]
                                                           | (_,_,auxVar,_) <- focusNames_b ])

                                , contiguousCountsCons
                                , buildOffSetsCons
                                , freezeFrameCons

                                , consOut
                                , impliedSize
                                ]
                            ])

                return out
            )

