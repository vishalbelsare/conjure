{-# LANGUAGE QuasiQuotes #-}

module Conjure.Representations.Set.ExplicitVarSizeWithDummy ( setExplicitVarSizeWithDummy ) where

-- conjure
import Conjure.Prelude
import Conjure.Bug
import Conjure.Language
import Conjure.Language.DomainSizeOf
import Conjure.Language.Expression.DomainSizeOf ()
import Conjure.Representations.Internal
import Conjure.Representations.Common


setExplicitVarSizeWithDummy :: forall m . (MonadFail m, NameGen m) => Representation m
setExplicitVarSizeWithDummy = Representation chck downD structuralCons downC up

    where

        chck :: TypeOf_ReprCheck m
        chck _ (DomainSet _ (SetAttr SizeAttr_Size{}) _) = return []
        chck f (DomainSet _ attrs innerDomain@(DomainInt{})) =
            map (DomainSet Set_ExplicitVarSizeWithDummy attrs) <$> f innerDomain
        chck _ _ = return []

        outName :: Name -> Name
        outName = mkOutName Set_ExplicitVarSizeWithDummy Nothing

        getMaxSize attrs innerDomain = case attrs of
            SizeAttr_MaxSize x -> return x
            SizeAttr_MinMaxSize _ x -> return x
            _ -> domainSizeOf innerDomain

        calcDummyElem :: Pretty r => Domain r Expression -> Expression
        calcDummyElem dom = [essence| 1 + max(`&dom`) |]

        calcDummyElemC :: Pretty r => Domain r Constant -> Constant
        calcDummyElemC (DomainInt []) = bug "ExplicitVarSizeWithDummy.calcDummyElemC []"
        calcDummyElemC (DomainInt rs) = ConstantInt $
            1 + maximum [ i
                        | r <- rs
                        , i <- case r of
                            RangeSingle (ConstantInt x) -> [x]
                            RangeBounded (ConstantInt x) (ConstantInt y) -> [x..y]
                            _ -> bug ("ExplicitVarSizeWithDummy.calcDummyElemC" <+> pretty r)
                        ]
        calcDummyElemC d = bug ("ExplicitVarSizeWithDummy.calcDummyElemC" <+> pretty d)

        downD :: TypeOf_DownD m
        downD (name, DomainSet Set_ExplicitVarSizeWithDummy (SetAttr attrs) innerDomain@(DomainInt ranges)) = do
            let dummyElem = calcDummyElem innerDomain
            maxSize <- getMaxSize attrs innerDomain
            return $ Just
                [ ( outName name
                  , DomainMatrix
                      (DomainInt [RangeBounded 1 maxSize])
                      (DomainInt (ranges ++ [RangeSingle dummyElem]))
                  ) ]
        downD _ = na "{downD} ExplicitVarSizeWithDummy"

        structuralCons :: TypeOf_Structural m
        structuralCons f downX1 (DomainSet Set_ExplicitVarSizeWithDummy (SetAttr attrs) innerDomain) = do
            maxSize <- getMaxSize attrs innerDomain
            let
                dummyElem = calcDummyElem innerDomain

                ordering m = do
                    (iPat, i) <- quantifiedVar
                    return $ return -- for list
                        [essence|
                            forAll &iPat : int(1..&maxSize-1) .
                                (&m[&i] .< &m[&i+1]) \/ (&m[&i] = &dummyElem)
                        |]

                dummyToTheRight m = do
                    (iPat, i) <- quantifiedVar
                    return $ return -- for list
                        [essence|
                            forAll &iPat : int(1..&maxSize-1) .
                                (&m[&i] = &dummyElem) -> (&m[&i+1] = &dummyElem)
                        |]

                cardinality m = do
                    (iPat, i) <- quantifiedVar
                    return [essence| sum &iPat : int(1..&maxSize) . toInt(&m[&i] != &dummyElem) |]

                innerStructuralCons m = do
                    (iPat, i) <- quantifiedVar
                    let activeZone b = [essence| forAll &iPat : int(1..&maxSize) . &m[&i] != &dummyElem -> &b |]

                    -- preparing structural constraints for the inner guys
                    innerStructuralConsGen <- f innerDomain

                    let inLoop = [essence| &m[&i] |]
                    outs <- innerStructuralConsGen inLoop
                    return (map activeZone outs)

            return $ \ ref -> do
                refs <- downX1 ref
                case refs of
                    [m] ->
                        concat <$> sequence
                            [ ordering m
                            , dummyToTheRight m
                            , mkSizeCons attrs <$> cardinality m
                            , innerStructuralCons m
                            ]
                    _ -> na "{structuralCons} ExplicitVarSizeWithDummy"
        structuralCons _ _ _ = na "{structuralCons} ExplicitVarSizeWithDummy"

        downC :: TypeOf_DownC m
        downC ( name
              , domain@(DomainSet Set_ExplicitVarSizeWithDummy (SetAttr attrs) innerDomain)
              , ConstantAbstract (AbsLitSet constants)
              ) = do
            maxSize <- getMaxSize attrs innerDomain
            let indexDomain i = mkDomainIntB (fromInt i) maxSize
            maxSizeInt <-
                case maxSize of
                    ConstantInt x -> return x
                    _ -> fail $ vcat
                            [ "Expecting an integer for the maxSize attribute."
                            , "But got:" <+> pretty maxSize
                            , "When working on:" <+> pretty name
                            , "With domain:" <+> pretty domain
                            ]
            let dummyElem = calcDummyElemC innerDomain
            let dummies = replicate (fromInteger (maxSizeInt - genericLength constants)) dummyElem
            return $ Just
                [ ( outName name
                  , DomainMatrix (indexDomain 1) innerDomain
                  , ConstantAbstract $ AbsLitMatrix (indexDomain 1) (constants ++ dummies)
                  )
                ]
        downC _ = na "{downC} ExplicitVarSizeWithDummy"

        up :: TypeOf_Up m
        up ctxt (name, domain@(DomainSet Set_ExplicitVarSizeWithDummy _ innerDomain)) = do
            let dummyElem = calcDummyElemC innerDomain
            case lookup (outName name) ctxt of
                Nothing -> fail $ vcat $
                    [ "(in Set ExplicitVarSizeWithDummy up)"
                    , "No value for:" <+> pretty (outName name)
                    , "When working on:" <+> pretty name
                    , "With domain:" <+> pretty domain
                    ] ++
                    ("Bindings in context:" : prettyContext ctxt)
                Just constant ->
                    case viewConstantMatrix constant of
                        Just (_, vals) ->
                            return (name, ConstantAbstract (AbsLitSet [ v | v <- vals, v /= dummyElem ]))
                        _ -> fail $ vcat
                                [ "Expecting a matrix literal for:" <+> pretty (outName name)
                                , "But got:" <+> pretty constant
                                , "When working on:" <+> pretty name
                                , "With domain:" <+> pretty domain
                                ]
        up _ _ = na "{up} ExplicitVarSizeWithDummy"