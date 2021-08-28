package server

import (
	"errors"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"time"

	"github.com/gorilla/mux"
)

const (
	cookieUserID  = "bieteruser"
	cookieAdminPW = "bieteradmin"
)

func registerHandlers(router *mux.Router, config Config, db *Database) {
	router.Use(loggingMiddleware)

	handleStatic(router)
	handleFrontpage(router, db)
	handleCreate(router, db)
	handleUpdate(router, db)
	handleAdmin(router, db, config)
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Println(r.RequestURI)
		next.ServeHTTP(w, r)
	})
}

func loadTemplate(name string) *template.Template {
	return template.Must(template.ParseFiles("./templates/main.gohtml", "./templates/"+name+".gohtml"))
}

func handleStatic(router *mux.Router) {
	router.PathPrefix("/static/").Handler(http.StripPrefix("/static/", http.FileServer(http.Dir("./static"))))
}

func handleFrontpage(router *mux.Router, db *Database) {
	frontpage := router.Path("/").Methods("GET").Subrouter()

	withQuery := frontpage.Queries("user_id", "")

	noCookie := frontpage.MatcherFunc(func(r *http.Request, rm *mux.RouteMatch) bool {
		_, err := r.Cookie(cookieUserID)
		return errors.Is(err, http.ErrNoCookie)
	})

	withCookie := frontpage.MatcherFunc(func(r *http.Request, rm *mux.RouteMatch) bool {
		_, err := r.Cookie(cookieUserID)
		return err == nil
	})

	withQuery.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		userID := r.URL.Query().Get("user_id")
		if userID == "" {
			// logout
			http.SetCookie(w, &http.Cookie{
				Name:    cookieUserID,
				Value:   "",
				Expires: time.Unix(0, 0),
			})
			http.Redirect(w, r, "/", 302)
			return
		}

		_, exist := db.User(userID)
		if !exist {
			http.Error(w, "Unbekannter Nutzer", 404)
			return
		}

		http.SetCookie(w, &http.Cookie{
			Name:  cookieUserID,
			Value: userID,
		})
		http.Redirect(w, r, "/", 302)
		return
	})

	tmplNoCookie := loadTemplate("frontpage_no_cookie")
	noCookie.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := tmplNoCookie.Execute(w, nil); err != nil {
			log.Println(err)
			http.Error(w, "Interner Fehler", 500)
			return
		}
	})

	tmplWithCookie := loadTemplate("frontpage_with_cookie")
	withCookie.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cookie, _ := r.Cookie(cookieUserID)
		user, exist := db.User(cookie.Value)
		if !exist {
			http.Error(w, "unbekannter Nutzer", 404)
			return
		}

		if err := tmplWithCookie.Execute(w, user); err != nil {
			log.Println(err)
			http.Error(w, "Interner Fehler", 500)
		}
	})
}

func handleCreate(router *mux.Router, db *Database) {
	router.Path("/create").Methods("POST").HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			if err := r.ParseForm(); err != nil {
				http.Error(w, "Invalid data", 400)
				return
			}

			userID, err := db.NewUser(r.PostFormValue("name"))
			if err != nil {
				log.Printf("Error: %v", err)
				http.Error(w, "Internal", 500)
				return
			}

			http.SetCookie(w, &http.Cookie{
				Name:  cookieUserID,
				Value: userID,
			})

			http.Redirect(w, r, "/", 302)
		},
	)
}

func handleUpdate(router *mux.Router, db *Database) {
	page := router.Path("/update").Subrouter()
	getRequet := page.Methods("GET")
	postRequet := page.Methods("POST")

	tmpl := loadTemplate("update")
	getRequet.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie(cookieUserID)
		if errors.Is(err, http.ErrNoCookie) {
			http.Error(w, "Unbekannter Nutzer", 404)
			return
		}
		if err != nil {
			http.Error(w, "Interner Fehler", 500)
			return
		}

		user, exist := db.User(cookie.Value)
		if !exist {
			http.Error(w, "Unbekannter Nutzer", 404)
			return
		}

		if err := tmpl.Execute(w, user); err != nil {
			log.Println(err)
			http.Error(w, "Interner Fehler", 500)
		}
	})

	postRequet.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			http.Error(w, "Invalid data", 400)
			return
		}

		cookie, err := r.Cookie(cookieUserID)
		if errors.Is(err, http.ErrNoCookie) {
			http.Error(w, "Unbekannter Nutzer", 404)
			return
		}
		if err != nil {
			http.Error(w, "Interner Fehler", 500)
			return
		}

		event, err := newUpdateEvent(
			cookie.Value,
			r.PostForm.Get("name"),
			r.PostForm.Get("adress"),
			r.PostForm.Get("iban"),
		)
		if err != nil {
			http.Error(w, fmt.Sprintf("ungiltige daten: %v", err), 400)
			return
		}

		if err := db.writeEvent(event); err != nil {
			log.Printf("Error: %v", err)
			http.Error(w, "Interner Fehler", 500)
		}

		http.Redirect(w, r, "/", 302)
	})
}

func handleAdmin(router *mux.Router, db *Database, c Config) {
	if c.AdminPW == "" {
		return
	}

	page := router.Path("/admin").Subrouter()

	noCookie := page.Methods("GET").MatcherFunc(func(r *http.Request, rm *mux.RouteMatch) bool {
		_, err := r.Cookie(cookieAdminPW)
		return errors.Is(err, http.ErrNoCookie)
	})

	withCookie := page.Methods("GET").MatcherFunc(func(r *http.Request, rm *mux.RouteMatch) bool {
		_, err := r.Cookie(cookieAdminPW)
		return err == nil
	})

	postRequest := page.Methods("POST")

	tmplNoCookie := loadTemplate("admin_no_cookie")
	noCookie.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := tmplNoCookie.Execute(w, nil); err != nil {
			log.Println(err)
			http.Error(w, "Interner Fehler", 500)
			return
		}
	})

	postRequest.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()

		adminPW := r.PostFormValue("admin_password")
		if adminPW == "" {
			// logout
			http.SetCookie(w, &http.Cookie{
				Name:    cookieAdminPW,
				Value:   "",
				Expires: time.Unix(0, 0),
			})
			http.Redirect(w, r, "/", 302)
			return
		}

		if adminPW != c.AdminPW {
			http.Error(w, "Nicht erlaubt", 403)
			return
		}

		http.SetCookie(w, &http.Cookie{
			Name:  cookieAdminPW,
			Value: adminPW,
		})
		http.Redirect(w, r, "/admin", 302)
	})

	tmpl := loadTemplate("admin")
	withCookie.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cookie, _ := r.Cookie(cookieAdminPW)
		if cookie.Value != c.AdminPW {
			http.Error(w, "Nicht erlaubt", 403)
			return
		}

		type User struct {
			UserID  string
			Name    string
			Adresse string
			IBAN    string
		}

		var data struct {
			Users []User
			Name  interface{}
		}
		for id, user := range db.Users() {
			data.Users = append(data.Users, User{
				UserID:  id,
				Name:    user.Name,
				Adresse: user.Adresse,
				IBAN:    user.IBAN,
			})
		}

		if err := tmpl.Execute(w, data); err != nil {
			log.Println(err)
			http.Error(w, "Interner Fehler", 500)
			return
		}
	})
}
