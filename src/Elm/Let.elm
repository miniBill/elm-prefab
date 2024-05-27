module Elm.Let exposing
    ( letIn, value, unpack, Let
    , fn, fn2, fn3
    , toExpression, withBody
    )

{-| This module is for building `let` expressions.

@docs letIn, value, unpack, Let

Here's a brief example to get you started

    import Elm
    import Elm.Let as Let

    Let.letIn
        (\one two ->
            Elm.Op.append one two
        )
        |> Let.value "one" (Elm.string "Hello")
        |> Let.value "two" (Elm.string "World!")
        |> Let.toExpression

Will translate into

    let
        one =
            "Hello!"

        two =
            "World"
    in
    one ++ two


# Destructing values

Here's an example destructing a tuple. This code

    import Elm
    import Elm.Let as Let
    import Elm.Arg as Arg


    Let.letIn
        (\( first, second ) ->
            Elm.Op.append first second
        )
        |> Let.unpack
            (Arg.tuple
                (Arg.var "first")
                (Arg.var "second")
            )
            (Elm.tuple
                (Elm.string "Hello")
                (Elm.string "World!")
            )
        |> Let.toExpression

Will generate

    let
        ( first, second ) =
            ( "Hello", "World!" )
    in
    first ++ second

And extracting fields from a record.

    import Elm
    import Elm.Let as Let
    import Elm.Arg as Arg

    Let.letIn
        (\{first, second } ->
            Elm.Op.append first second
        )
        |> Let.unpack
            (Arg.record (\first second -> {first, second})
            |> Arg.field "first"
            |> Arg.field "second"

            )
            (Elm.record
                [ ( "first", Elm.string "Hello" )
                , ( "second", Elm.string "world!" )
                ]
            )
        |> Let.toExpression

Will generate:

    let
        { first, second } =
            { first = "Hello", second = "world!" }
    in
    first ++ second


# Functions

Here's an example of declaring functions in a let expression:

    import Elm
    import Elm.Let as Let

    Let.letIn
        (\myFn ->
            myFn (Elm.bool True)
        )
        |> Let.fn "myFn"
            ( "arg", Just Type.bool )
            (\arg ->
                Elm.ifThen arg
                    (Elm.string "True")
                    (Elm.string "False")
            )
        |> Let.toExpression

will generate

    let
        myFn arg =
            if arg then
                "True"

            else
                "False"
    in
    myFn True

@docs fn, fn2, fn3


# Converting to an Expression

@docs toExpression, withBody

-}

import Elm exposing (Expression)
import Elm.Annotation
import Elm.Arg
import Elm.Syntax.Expression as Exp
import Elm.Syntax.Node as Node
import Elm.Syntax.Pattern as Pattern
import Internal.Arg
import Internal.Compiler as Compiler exposing (Module)
import Internal.Index as Index


{-| -}
type Let a
    = Let
        (Index.Index
         ->
            { letDecls : List (Node.Node Exp.LetDeclaration)
            , index : Index.Index
            , return : a
            , imports : List Module
            }
        )


{-| -}
letIn : a -> Let a
letIn return =
    Let
        (\index ->
            { letDecls = []
            , index = index
            , return = return
            , imports = []
            }
        )


{-| -}
unpack : Elm.Arg.Arg arg -> Expression -> Let (arg -> b) -> Let b
unpack argument bodyExpression (Let toLetScope) =
    Let
        (\index ->
            let
                argDetails =
                    Internal.Arg.toDetails index argument

                ( threeIndex, bodyDetails ) =
                    Compiler.toExpressionDetails argDetails.index bodyExpression

                previousLet :
                    { letDecls : List (Node.Node Exp.LetDeclaration)
                    , index : Index.Index
                    , return : arg -> b
                    , imports : List Module
                    }
                previousLet =
                    toLetScope threeIndex

                decl =
                    Compiler.nodify <|
                        Exp.LetDestructuring
                            argDetails.details.pattern
                            (Compiler.nodify bodyDetails.expression)
            in
            { letDecls = decl :: previousLet.letDecls
            , index = previousLet.index
            , return = previousLet.return argDetails.value
            , imports = argDetails.details.imports ++ previousLet.imports
            }
        )


with : Let a -> Let (a -> b) -> Let b
with (Let toScopeA) (Let toScopeAB) =
    Let
        (\index ->
            let
                resultA : { letDecls : List (Node.Node Exp.LetDeclaration), index : Index.Index, return : a, imports : List Module }
                resultA =
                    toScopeA index

                resultB : { letDecls : List (Node.Node Exp.LetDeclaration), index : Index.Index, return : a -> b, imports : List Module }
                resultB =
                    toScopeAB resultA.index
            in
            { letDecls = resultA.letDecls ++ resultB.letDecls
            , index = resultB.index
            , return = resultB.return resultA.return
            , imports = resultA.imports ++ resultB.imports
            }
        )


{-| -}
value : String -> Expression -> Let (Expression -> a) -> Let a
value desiredName valueExpr sourceLet =
    with
        (Let
            (\index ->
                let
                    ( name, secondIndex ) =
                        Index.getName desiredName index

                    ( finalIndex, details ) =
                        Compiler.toExpressionDetails secondIndex valueExpr
                in
                { letDecls =
                    [ case details.expression of
                        Exp.LambdaExpression lamb ->
                            Compiler.nodify <|
                                Exp.LetFunction
                                    { documentation = Nothing
                                    , signature = Nothing
                                    , declaration =
                                        Compiler.nodify
                                            { name = Compiler.nodify name
                                            , arguments =
                                                lamb.args
                                            , expression =
                                                lamb.expression
                                            }
                                    }

                        _ ->
                            Compiler.nodify <|
                                Exp.LetDestructuring
                                    (Compiler.nodify
                                        (Pattern.VarPattern name)
                                    )
                                    (Compiler.nodify details.expression)
                    ]
                , index = finalIndex
                , return =
                    Compiler.Expression
                        (\_ ->
                            { details
                                | expression =
                                    Exp.FunctionOrValue []
                                        name
                            }
                        )
                , imports = details.imports
                }
            )
        )
        sourceLet


{-| -}
fn :
    String
    -> ( String, Maybe Elm.Annotation.Annotation )
    -> (Expression -> Expression)
    -> Let ((Expression -> Expression) -> a)
    -> Let a
fn desiredName ( desiredArg, argAnnotation ) toInnerFn sourceLet =
    with
        (Let
            (\index ->
                let
                    ( name, secondIndex ) =
                        Index.getName desiredName index

                    ( argName, thirdIndex ) =
                        Index.getName desiredArg secondIndex

                    arg : Expression
                    arg =
                        Elm.value
                            { importFrom = []
                            , annotation = argAnnotation
                            , name = argName
                            }

                    ( finalIndex, innerFnDetails ) =
                        Compiler.toExpressionDetails thirdIndex
                            (toInnerFn arg)
                in
                { letDecls =
                    [ Compiler.nodify <|
                        Exp.LetFunction
                            { documentation = Nothing
                            , signature = Nothing
                            , declaration =
                                Compiler.nodify
                                    { name = Compiler.nodify name
                                    , arguments =
                                        [ Compiler.nodify
                                            (Pattern.VarPattern argName)
                                        ]
                                    , expression =
                                        Compiler.nodify innerFnDetails.expression
                                    }
                            }
                    ]
                , index = finalIndex
                , imports = innerFnDetails.imports
                , return =
                    \callerArg ->
                        Elm.apply
                            (Compiler.Expression
                                (\_ ->
                                    { innerFnDetails
                                        | expression =
                                            Exp.FunctionOrValue []
                                                name
                                    }
                                )
                            )
                            [ callerArg
                            ]
                }
            )
        )
        sourceLet


{-| -}
fn2 :
    String
    -> ( String, Maybe Elm.Annotation.Annotation )
    -> ( String, Maybe Elm.Annotation.Annotation )
    -> (Expression -> Expression -> Expression)
    -> Let ((Expression -> Expression -> Expression) -> a)
    -> Let a
fn2 desiredName ( oneDesiredArg, oneType ) ( twoDesiredArg, twoType ) toInnerFn sourceLet =
    with
        (Let
            (\index ->
                let
                    ( name, secondIndex ) =
                        Index.getName desiredName index

                    ( oneName, thirdIndex ) =
                        Index.getName oneDesiredArg secondIndex

                    ( twoName, fourIndex ) =
                        Index.getName twoDesiredArg thirdIndex

                    one : Expression
                    one =
                        Elm.value
                            { importFrom = []
                            , annotation = oneType
                            , name = oneName
                            }

                    two : Expression
                    two =
                        Elm.value
                            { importFrom = []
                            , annotation = twoType
                            , name = twoName
                            }

                    ( finalIndex, innerFnDetails ) =
                        Compiler.toExpressionDetails fourIndex
                            (toInnerFn one two)
                in
                { letDecls =
                    [ Compiler.nodify <|
                        Exp.LetFunction
                            { documentation = Nothing
                            , signature = Nothing
                            , declaration =
                                Compiler.nodify
                                    { name = Compiler.nodify name
                                    , arguments =
                                        [ Compiler.nodify
                                            (Pattern.VarPattern oneName)
                                        , Compiler.nodify
                                            (Pattern.VarPattern twoName)
                                        ]
                                    , expression =
                                        Compiler.nodify innerFnDetails.expression
                                    }
                            }
                    ]
                , index = finalIndex
                , imports = innerFnDetails.imports
                , return =
                    \oneIncoming twoIncoming ->
                        Elm.apply
                            (Compiler.Expression
                                (\_ ->
                                    { innerFnDetails
                                        | expression =
                                            Exp.FunctionOrValue []
                                                name
                                    }
                                )
                            )
                            [ oneIncoming
                            , twoIncoming
                            ]
                }
            )
        )
        sourceLet


{-| -}
fn3 :
    String
    -> ( String, Maybe Elm.Annotation.Annotation )
    -> ( String, Maybe Elm.Annotation.Annotation )
    -> ( String, Maybe Elm.Annotation.Annotation )
    -> (Expression -> Expression -> Expression -> Expression)
    -> Let ((Expression -> Expression -> Expression -> Expression) -> a)
    -> Let a
fn3 desiredName ( oneDesiredArg, oneType ) ( twoDesiredArg, twoType ) ( threeDesiredArg, threeType ) toInnerFn sourceLet =
    with
        (Let
            (\index ->
                let
                    ( name, secondIndex ) =
                        Index.getName desiredName index

                    ( oneName, thirdIndex ) =
                        Index.getName oneDesiredArg secondIndex

                    ( twoName, fourIndex ) =
                        Index.getName twoDesiredArg thirdIndex

                    ( threeName, fifthIndex ) =
                        Index.getName threeDesiredArg fourIndex

                    one : Expression
                    one =
                        Elm.value
                            { importFrom = []
                            , annotation = oneType
                            , name = oneName
                            }

                    two : Expression
                    two =
                        Elm.value
                            { importFrom = []
                            , annotation = twoType
                            , name = twoName
                            }

                    three : Expression
                    three =
                        Elm.value
                            { importFrom = []
                            , annotation = threeType
                            , name = threeName
                            }

                    ( finalIndex, innerFnDetails ) =
                        Compiler.toExpressionDetails fifthIndex
                            (toInnerFn one two three)
                in
                { letDecls =
                    [ Compiler.nodify <|
                        Exp.LetFunction
                            { documentation = Nothing
                            , signature = Nothing
                            , declaration =
                                Compiler.nodify
                                    { name = Compiler.nodify name
                                    , arguments =
                                        [ Compiler.nodify
                                            (Pattern.VarPattern oneName)
                                        , Compiler.nodify
                                            (Pattern.VarPattern twoName)
                                        , Compiler.nodify
                                            (Pattern.VarPattern threeName)
                                        ]
                                    , expression =
                                        Compiler.nodify innerFnDetails.expression
                                    }
                            }
                    ]
                , index = finalIndex
                , imports = innerFnDetails.imports
                , return =
                    \oneIncoming twoIncoming threeIncoming ->
                        Elm.apply
                            (Compiler.Expression
                                (\_ ->
                                    { innerFnDetails
                                        | expression =
                                            Exp.FunctionOrValue []
                                                name
                                    }
                                )
                            )
                            [ oneIncoming
                            , twoIncoming
                            , threeIncoming
                            ]
                }
            )
        )
        sourceLet


{-| -}
toExpression : Let Expression -> Expression
toExpression (Let toScope) =
    Compiler.Expression <|
        \index ->
            let
                scope : { letDecls : List (Node.Node Exp.LetDeclaration), index : Index.Index, return : Expression, imports : List Module }
                scope =
                    toScope index

                ( _, return ) =
                    Compiler.toExpressionDetails scope.index scope.return
            in
            { expression =
                -- if we're leading into another let expression, just merge with it.
                case return.expression of
                    Exp.LetExpression innerReturn ->
                        Exp.LetExpression
                            { declarations =
                                List.reverse scope.letDecls
                                    ++ innerReturn.declarations
                            , expression = innerReturn.expression
                            }

                    _ ->
                        Exp.LetExpression
                            { declarations = List.reverse scope.letDecls
                            , expression = Compiler.nodify return.expression
                            }
            , imports = return.imports ++ scope.imports
            , annotation =
                return.annotation
            }


{-| Define the body of your `let` at the bottom instead of the top so it matches the generated syntax a bit closer.

These two are equivalent
import Elm
import Elm.Let as Let

      Let.letIn
          (\one two ->
              Elm.Op.append one two
          )
          |> Let.value "one" (Elm.string "Hello")
          |> Let.value "two" (Elm.string "World!")
          |> Let.toExpression


      Let.letIn Tuple.pair
          |> Let.value "one" (Elm.string "Hello")
          |> Let.value "two" (Elm.string "World!")
          |> Let.withBody
              (\(one, two) ->
                  Elm.Op.append one two
              )

And will generate

      let
          one = "Hello"
          two = "World!"
      in
      one ++ two

-}
withBody : (val -> Expression) -> Let val -> Expression
withBody toBody (Let toScope) =
    Compiler.Expression <|
        \index ->
            let
                letDetails :
                    { letDecls : List (Node.Node Exp.LetDeclaration)
                    , index : Index.Index
                    , return : val
                    , imports : List Module
                    }
                letDetails =
                    toScope index

                ( _, return ) =
                    letDetails.return
                        |> toBody
                        |> Compiler.toExpressionDetails letDetails.index
            in
            { expression =
                -- if we're leading into another let expression, just merge with it.
                case return.expression of
                    Exp.LetExpression innerReturn ->
                        Exp.LetExpression
                            { declarations =
                                List.reverse letDetails.letDecls
                                    ++ innerReturn.declarations
                            , expression = innerReturn.expression
                            }

                    _ ->
                        Exp.LetExpression
                            { declarations = List.reverse letDetails.letDecls
                            , expression = Compiler.nodify return.expression
                            }
            , imports = return.imports ++ letDetails.imports
            , annotation =
                return.annotation
            }
