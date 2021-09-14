module Page.Front exposing (Model, Msg, init, toSession, update, updateSession, view)

import Bieter
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Http
import IBAN
import Json.Encode as Encode
import Offer
import Permission
import QRCode
import Route
import Session exposing (Session)
import State
import Svg.Attributes as SvgA


type alias Model =
    { session : Session
    , page : Page
    , loginErrorMsg : Maybe String
    , loginFormBieterNr : String
    , loginFormBieterName : String
    , editErrorMsg : Maybe String
    , draftBieter : Maybe Bieter.Bieter
    , ibanValid : Bool
    , draftOffer : String
    , offerValid : Bool
    , offerErrorMsg : Maybe String
    }


type Page
    = Show
    | Edit


type EditPageMsg
    = FormSaveName String
    | FormSaveAdresse String
    | FormSaveIBAN String
    | FormSubmit
    | FormReceived (Result Http.Error Bieter.Bieter)
    | FormGoBack


type Msg
    = GotEditPageMsg EditPageMsg
    | GotoEditPage
    | RequestLogin
    | ReceivedLogin (Result Http.Error Bieter.Bieter)
    | RequestCreate
    | ReceivedCreate (Result Http.Error Bieter.Bieter)
    | SaveNumber String
    | SaveName String
    | SaveDraftOffer String
    | SendOffer
    | ReceiveOffer (Result Http.Error Offer.Offer)


init : Session -> ( Model, Cmd Msg )
init session =
    let
        bieterID =
            case Session.toBieterID session of
                Nothing ->
                    ""

                Just id ->
                    Bieter.idToString id

        offer =
            case Session.toBieter session of
                Nothing ->
                    ""

                Just bieter ->
                    Offer.toInputString bieter.offer
    in
    ( Model session Show Nothing bieterID "" Nothing Nothing False offer False Nothing, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        GotEditPageMsg editMsg ->
            updateEditPage model editMsg

        GotoEditPage ->
            ( { model | page = Edit, draftBieter = Session.toBieter model.session }
            , Cmd.none
            )

        SaveNumber nr ->
            ( { model | loginFormBieterNr = nr }
            , Cmd.none
            )

        SaveName name ->
            ( { model | loginFormBieterName = name }
            , Cmd.none
            )

        RequestLogin ->
            let
                ( newSession, cmd ) =
                    Session.loadBieter model.session ReceivedLogin (Bieter.idFromString model.loginFormBieterNr)
            in
            ( { model | session = newSession }, cmd )

        ReceivedLogin response ->
            case response of
                Ok bieter ->
                    let
                        ( newSession, cmd ) =
                            Session.loggedIn model.session bieter
                    in
                    ( { model | page = Show, session = newSession }
                    , cmd
                    )

                Err e ->
                    let
                        errMsg =
                            buildErrorMessage e
                    in
                    ( { model | loginErrorMsg = Just errMsg }
                    , Cmd.none
                    )

        RequestCreate ->
            ( model, createBieter model.session model.loginFormBieterName )

        ReceivedCreate response ->
            case response of
                Ok bieter ->
                    let
                        ( newSession, cmd ) =
                            Session.loggedIn model.session bieter
                    in
                    ( { model | page = Show, session = newSession }
                    , cmd
                    )

                Err e ->
                    let
                        errMsg =
                            buildErrorMessage e
                    in
                    ( { model | loginErrorMsg = Just errMsg }
                    , Cmd.none
                    )

        SaveDraftOffer draft ->
            ( { model | offerValid = Offer.valid draft, draftOffer = draft }
            , Cmd.none
            )

        SendOffer ->
            let
                maybeBieter =
                    Session.toBieter model.session

                offer =
                    Offer.fromInputString model.draftOffer
            in
            case ( maybeBieter, offer ) of
                ( Just bieter, Offer.Offer _ _ ) ->
                    ( model
                    , Offer.send ReceiveOffer (Session.headers model.session) (Bieter.idToString bieter.id) offer
                    )

                _ ->
                    ( { model | offerErrorMsg = Just "Ungültiges Gebot" }
                    , Cmd.none
                    )

        ReceiveOffer result ->
            case result of
                Ok offer ->
                    let
                        maybeBieter =
                            Session.toBieter model.session

                        newBieter =
                            Maybe.andThen (\bieter -> Just { bieter | offer = offer }) maybeBieter

                        maybeSessionCmd =
                            Maybe.andThen (\bieter -> Just (Session.loggedIn model.session bieter)) newBieter
                    in
                    case maybeSessionCmd of
                        Nothing ->
                            ( model, Cmd.none )

                        Just ( session, _ ) ->
                            ( { model | session = session }, Cmd.none )

                Err e ->
                    let
                        errMsg =
                            buildErrorMessage e
                    in
                    ( { model | offerErrorMsg = Just errMsg }
                    , Cmd.none
                    )


updateEditPage : Model -> EditPageMsg -> ( Model, Cmd Msg )
updateEditPage model editMsg =
    case model.draftBieter of
        Nothing ->
            ( model, Cmd.none )

        Just bieter ->
            case editMsg of
                FormSaveName name ->
                    ( { model | draftBieter = Just { bieter | name = name } }
                    , Cmd.none
                    )

                FormSaveAdresse addr ->
                    ( { model | draftBieter = Just { bieter | adresse = addr } }
                    , Cmd.none
                    )

                FormSaveIBAN iban ->
                    let
                        valid =
                            case IBAN.fromString iban of
                                Ok _ ->
                                    True

                                Err _ ->
                                    False
                    in
                    ( { model | ibanValid = valid, draftBieter = Just { bieter | iban = iban } }
                    , Cmd.none
                    )

                FormSubmit ->
                    ( model
                    , updateBieter model.session bieter
                    )

                FormReceived response ->
                    case response of
                        Ok _ ->
                            let
                                ( newSession, cmd ) =
                                    Session.loggedIn model.session bieter
                            in
                            ( { model | page = Show, session = newSession }
                            , cmd
                            )

                        Err e ->
                            ( { model | editErrorMsg = Just (buildErrorMessage e) }
                            , Cmd.none
                            )

                FormGoBack ->
                    ( { model | page = Show }
                    , Cmd.none
                    )


createBieter : Session -> String -> Cmd Msg
createBieter session name =
    Http.request
        { method = "POST"
        , headers = Session.headers session
        , url = "/api/bieter"
        , body = Http.jsonBody (bieterNameEncoder name)
        , expect = Http.expectJson ReceivedCreate Bieter.bieterDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


updateBieter : Session -> Bieter.Bieter -> Cmd Msg
updateBieter session bieter =
    Http.request
        { method = "PUT"
        , headers = Session.headers session
        , url = "/api/bieter/" ++ Bieter.idToString bieter.id
        , body = Http.jsonBody (Bieter.bieterEncoder bieter)
        , expect = Http.expectJson FormReceived Bieter.bieterDecoder
        , timeout = Nothing
        , tracker = Nothing
        }
        |> Cmd.map GotEditPageMsg


bieterNameEncoder : String -> Encode.Value
bieterNameEncoder name =
    Encode.object
        [ ( "name", Encode.string name ) ]


buildErrorMessage : Http.Error -> String
buildErrorMessage httpError =
    case httpError of
        Http.BadUrl message ->
            message

        Http.Timeout ->
            "Server is taking too long to respond. Please try again later."

        Http.NetworkError ->
            "Unable to reach server."

        Http.BadStatus statusCode ->
            case statusCode of
                404 ->
                    "Unbekannte Bieternummer"

                _ ->
                    "Request failed with status code: " ++ String.fromInt statusCode

        Http.BadBody message ->
            message


view : Model -> { title : String, content : Html Msg }
view model =
    let
        maybeBieter =
            Session.toBieter model.session
    in
    case maybeBieter of
        Nothing ->
            viewLogin model

        Just bieter ->
            case model.page of
                Show ->
                    viewBieter model.session model.session.baseURL bieter model.draftOffer model.offerErrorMsg model.offerValid

                Edit ->
                    let
                        { title, content } =
                            viewEdit model
                    in
                    { title = title
                    , content = Html.map GotEditPageMsg content
                    }


viewLogin : Model -> { title : String, content : Html Msg }
viewLogin loginData =
    { title = "Login title"
    , content =
        div []
            [ h1 [] [ text "Mit Bieternummer anmelden" ]
            , maybeError loginData.loginErrorMsg
            , Html.form [ onSubmit RequestLogin ]
                [ div []
                    [ text "Bieternummer"
                    , input
                        [ id "nummer"
                        , type_ "text"
                        , value loginData.loginFormBieterNr
                        , onInput SaveNumber
                        ]
                        []
                    ]
                , div []
                    [ button
                        [ type_ "submit" ]
                        [ text "Anmelden" ]
                    ]
                ]
            , viewCreateForm loginData
            ]
    }


viewCreateForm : Model -> Html Msg
viewCreateForm model =
    if Permission.hasPerm Permission.CanCreate model.session then
        div []
            [ h1 [] [ text "Neue Bieternummer anlegen" ]
            , Html.form [ onSubmit RequestCreate ]
                [ div []
                    [ text "Bieternummer"
                    , input
                        [ id "name"
                        , type_ "text"
                        , value model.loginFormBieterName
                        , onInput SaveName
                        ]
                        []
                    ]
                , div []
                    [ button
                        [ type_ "submit" ]
                        [ text "Anlegen" ]
                    ]
                ]
            ]

    else
        text ""


maybeError : Maybe String -> Html msg
maybeError errorMsg =
    case errorMsg of
        Just message ->
            div [] [ strong [] [ text "Fehler:" ], text (" " ++ message) ]

        Nothing ->
            text ""


viewBieter : Session -> String -> Bieter.Bieter -> String -> Maybe String -> Bool -> { title : String, content : Html Msg }
viewBieter session baseURL bieter draftOffer error offerValid =
    let
        maybeEditButton =
            if Permission.hasPerm Permission.CanEdit session then
                div [] [ button [ onClick GotoEditPage ] [ text "Bearbeiten" ] ]

            else
                text ""
    in
    { title = "Bieter"
    , content =
        div []
            [ h1 [] [ text ("Hallo " ++ bieter.name) ]
            , div []
                [ text "Deine Bieternummer ist "
                , strong [] [ text (Bieter.idToString bieter.id) ]
                , text ". Merke sie dir gut. Du brauchst sie für die nächste anmeldung"
                ]
            , div [] [ text ("Adresse: " ++ bieter.adresse) ]
            , div [] [ text ("IBAN: " ++ bieter.iban) ]
            , maybeEditButton
            , viewOffer session bieter draftOffer error offerValid
            , viewQRCode baseURL bieter.id
            ]
    }


viewOffer : Session -> Bieter.Bieter -> String -> Maybe String -> Bool -> Html Msg
viewOffer session bieter draftOffer error offerValid =
    div []
        [ text (Offer.toString bieter.offer)
        , if Permission.hasPerm Permission.CanOffer session then
            Html.form [ onSubmit SendOffer ]
                [ maybeError error
                , input
                    [ type_ "text"
                    , value draftOffer
                    , onInput SaveDraftOffer
                    , class
                        (if offerValid then
                            ""

                         else
                            "error"
                        )
                    ]
                    []
                , button [ type_ "submit" ] [ text "abgeben" ]
                ]

          else
            text ""
        ]


viewQRCode : String -> Bieter.ID -> Html msg
viewQRCode baseURL id =
    let
        message =
            baseURL ++ Route.routeToString (Route.Bieter id)
    in
    div []
        [ QRCode.fromString message
            |> Result.map
                (QRCode.toSvg
                    [ SvgA.width "100px"
                    , SvgA.height "100px"
                    ]
                )
            |> Result.withDefault (Html.text "Error while encoding to QRCode.")
        ]


viewEdit : Model -> { title : String, content : Html EditPageMsg }
viewEdit model =
    case model.draftBieter of
        Nothing ->
            { title = "Error", content = text "TODO invalid state. DraftBieter is Nothing on edit view" }

        Just bieter ->
            { title = "Edit Bieter " ++ bieter.name
            , content =
                div []
                    [ maybeError model.editErrorMsg
                    , div []
                        [ text "Name"
                        , input
                            [ type_ "text"
                            , value bieter.name
                            , onInput FormSaveName
                            ]
                            []
                        ]
                    , div []
                        [ text "Adresse"
                        , input
                            [ type_ "text"
                            , value bieter.adresse
                            , onInput FormSaveAdresse
                            ]
                            []
                        ]
                    , div []
                        [ text "IBAN"
                        , input
                            [ type_ "text"
                            , class
                                (if model.ibanValid then
                                    ""

                                 else
                                    "error"
                                )
                            , value bieter.iban
                            , onInput FormSaveIBAN
                            ]
                            []
                        ]
                    , div []
                        [ button
                            [ onClick FormSubmit ]
                            [ text "Speichern" ]
                        , button
                            [ onClick FormGoBack ]
                            [ text "Zurück" ]
                        ]
                    ]
            }


toSession : Model -> Session
toSession model =
    model.session


updateSession : Model -> Session -> Model
updateSession model session =
    { model | session = session }
