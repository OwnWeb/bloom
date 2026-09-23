@testable import BloomCore
import Foundation
import Testing

@Suite("DatabaseLogin")
struct DatabaseLoginTests {
    @Test("A Laravel .env gives a Postgres forward its user, password and database")
    func laravelPostgres() {
        let env = """
        APP_NAME=There
        DB_CONNECTION=pgsql
        DB_HOST=127.0.0.1
        DB_PORT=5432
        DB_DATABASE=there_there
        DB_USERNAME=sprite
        DB_PASSWORD="se cret#1"
        """
        #expect(DatabaseLogin.from(dotenv: env, scheme: "postgresql")
            == DatabaseLogin(user: "sprite", password: "se cret#1", database: "there_there"))
    }

    @Test("Another connection's login is never handed to this one")
    func connectionMustMatch() {
        let env = "DB_CONNECTION=mysql\nDB_USERNAME=root\nDB_DATABASE=app\n"
        #expect(DatabaseLogin.from(dotenv: env, scheme: "postgresql") == nil)
        #expect(DatabaseLogin.from(dotenv: env, scheme: "mysql") == DatabaseLogin(user: "root", database: "app"))
        #expect(DatabaseLogin.from(dotenv: "DB_CONNECTION=mariadb\nDB_USERNAME=root\n", scheme: "mysql")?.user == "root")
    }

    @Test("A URL variable of the same scheme wins over the separate keys")
    func databaseURL() {
        let env = """
        DATABASE_URL=postgres://app:p%40ss@localhost:5432/shop
        DB_USERNAME=ignored
        """
        #expect(DatabaseLogin.from(dotenv: env, scheme: "postgresql") == DatabaseLogin(user: "app", password: "p@ss", database: "shop"))
    }

    @Test("Redis takes its own keys, and Laravel's null means unset")
    func redis() {
        #expect(DatabaseLogin.from(dotenv: "REDIS_PASSWORD=null\n", scheme: "redis") == nil)
        #expect(DatabaseLogin.from(dotenv: "REDIS_PASSWORD=hunter2\n", scheme: "redis") == DatabaseLogin(password: "hunter2"))
    }

    @Test("Comments, export and quotes are read the way phpdotenv reads them")
    func parsing() {
        let values = DatabaseLogin.parse(dotenv: """
        # DB_USERNAME=commented
        export DB_USERNAME=app
        DB_DATABASE=shop # the main one
        DB_PASSWORD='a # b'
        DB_HOST=
        """)
        #expect(values == ["DB_USERNAME": "app", "DB_DATABASE": "shop", "DB_PASSWORD": "a # b"])
    }
}
