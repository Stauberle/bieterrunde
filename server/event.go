package server

import (
	"encoding/json"
	"fmt"
)

const (
	lowestOffer = 4000
)

func getEvent(eventType string) Event {
	switch eventType {
	case "update":
		return &eventUpdate{}

	case "delete":
		return &eventDelete{}

	case "state":
		return &eventServiceState{}

	case "offer":
		return &eventOffer{}

	case "offer-clear":
		return &eventOfferClear{}

	default:
		return nil
	}
}

// Event is one change of the database.
type Event interface {
	validate(db *Database) error
	execute(db *Database) error
	Name() string
}

type eventUpdate struct {
	ID      string          `json:"id"`
	Payload json.RawMessage `json:"payload"`
	create  bool
	asAdmin bool
}

func newEventCreate(id string, payload json.RawMessage, asAdmin bool) (eventUpdate, error) {
	e, err := newEventUpdate(id, payload, asAdmin)
	e.create = true
	return e, err
}

func newEventUpdate(id string, payload json.RawMessage, asAdmin bool) (eventUpdate, error) {
	if payload == nil {
		return eventUpdate{}, validationError{"Keine Daten übergeben"}
	}

	if !json.Valid(payload) {
		return eventUpdate{}, validationError{"Ungültige Daten übergeben"}
	}

	e := eventUpdate{
		ID:      id,
		Payload: payload,
		create:  false,
		asAdmin: asAdmin,
	}

	return e, nil
}

func (e eventUpdate) String() string {
	return fmt.Sprintf("Updating bieter %q to payload %q", e.ID, e.Payload)
}

func (e eventUpdate) Name() string {
	return "update"
}

func (e eventUpdate) validate(db *Database) error {
	if !e.asAdmin && db.state != stateRegistration {
		return validationError{"invalid state"}
	}

	_, exist := db.bieter[e.ID]
	if e.create {
		if exist {
			return errIDExists
		}
		return nil
	}

	if !exist {
		return validationError{fmt.Sprintf("Bieter %q does not exist", e.ID)}
	}
	return nil
}

func (e eventUpdate) execute(db *Database) error {
	db.bieter[e.ID] = e.Payload
	return nil
}

type eventDelete struct {
	ID      string `json:"id"`
	asAdmin bool
}

func newEventDelete(id string, asAdmin bool) eventDelete {
	return eventDelete{id, asAdmin}
}

func (e eventDelete) String() string {
	return fmt.Sprintf("Deleting bieter %q", e.ID)
}

func (e eventDelete) Name() string {
	return "delete"
}

func (e eventDelete) validate(db *Database) error {
	if !e.asAdmin && db.state != stateRegistration {
		return validationError{"invalid state"}
	}
	return nil
}

func (e eventDelete) execute(db *Database) error {
	delete(db.bieter, e.ID)
	return nil
}

type eventServiceState struct {
	NewState ServiceState `json:"state"`
}

func newEventStatus(newState ServiceState) (eventServiceState, error) {
	if int(newState) < 1 || int(newState) > 3 {
		return eventServiceState{}, validationError{fmt.Sprintf("Ungültiger State mit nummer %q", newState)}
	}
	return eventServiceState{newState}, nil
}

func (e eventServiceState) String() string {
	return fmt.Sprintf("Set state to %q", e.NewState.String())
}

func (e eventServiceState) Name() string {
	return "state"
}

func (e eventServiceState) validate(db *Database) error {
	return nil
}

func (e eventServiceState) execute(db *Database) error {
	db.state = e.NewState
	return nil
}

type eventOffer struct {
	ID      string `json:"id"`
	Offer   int    `json:"offer"`
	asAdmin bool
}

func newEventOffer(id string, offer int, asAdmin bool) (eventOffer, error) {
	if int(offer) < lowestOffer {
		return eventOffer{}, validationError{fmt.Sprintf("Das Gebot muss mindestens %d sein, nicht %q", lowestOffer, offer)}
	}
	return eventOffer{id, offer, asAdmin}, nil
}

func (e eventOffer) String() string {
	return fmt.Sprintf("Set offer of bieter %q to %d", e.ID, e.Offer)
}

func (e eventOffer) Name() string {
	return "offer"
}

func (e eventOffer) validate(db *Database) error {
	if !e.asAdmin && db.state != stateOffer {
		return validationError{"invalid state"}
	}
	if _, exist := db.bieter[e.ID]; !exist {
		return validationError{fmt.Sprintf("Bieter %q does not exist", e.ID)}
	}
	return nil
}

func (e eventOffer) execute(db *Database) error {
	db.offer[e.ID] = e.Offer
	return nil
}

type eventOfferClear struct{}

func newEventOfferClear() eventOfferClear {
	return eventOfferClear{}
}

func (e eventOfferClear) String() string {
	return fmt.Sprintf("Clear all offers")
}

func (e eventOfferClear) Name() string {
	return "offer-clear"
}

func (e eventOfferClear) validate(db *Database) error {
	return nil
}

func (e eventOfferClear) execute(db *Database) error {
	db.offer = make(map[string]int)
	return nil
}

type validationError struct {
	msg string
}

func (e validationError) Error() string {
	return e.msg
}

func (e validationError) forClient() string {
	return "Ungültige Daten: " + e.msg
}

var errIDExists = validationError{"Bieter ID existiert bereits"}
