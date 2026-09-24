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

    @Test("Postgres accepts its own URL and Docker or libpq variables")
    func postgresVariables() {
        #expect(DatabaseLogin.from(dotenv: "POSTGRES_URL=postgres://app:secret@db:5432/shop\n", scheme: "postgresql")
            == DatabaseLogin(user: "app", password: "secret", database: "shop"))
        #expect(DatabaseLogin.from(dotenv: "DB_CONNECTION=mysql\nPOSTGRES_USER=app\nPOSTGRES_DB=shop\n", scheme: "postgresql")
            == DatabaseLogin(user: "app", database: "shop"))
        #expect(DatabaseLogin.from(dotenv: "PGUSER=app\nPGPASSWORD=secret\nPGDATABASE=shop\n", scheme: "postgresql")
            == DatabaseLogin(user: "app", password: "secret", database: "shop"))
    }

    @Test("A Sprite's empty password still gives Postgres its user and database")
    func postgresWithoutPassword() {
        let env = "DB_CONNECTION=pgsql\nDB_DATABASE=therethere\nDB_USERNAME=postgres\nDB_PASSWORD=\n"
        #expect(DatabaseLogin.from(dotenv: env, scheme: "postgresql")
            == DatabaseLogin(user: "postgres", database: "therethere"))
    }

    @Test("MySQL accepts its own variables without borrowing a Postgres login")
    func mysqlVariables() {
        let env = "POSTGRES_USER=postgres\nMYSQL_USER=app\nMYSQL_PASSWORD=secret\nMYSQL_DATABASE=shop\n"
        #expect(DatabaseLogin.from(dotenv: env, scheme: "mysql")
            == DatabaseLogin(user: "app", password: "secret", database: "shop"))
        #expect(DatabaseLogin.from(dotenv: env, scheme: "postgresql") == DatabaseLogin(user: "postgres"))
    }

    @Test("Redis takes its own keys, and Laravel's null means unset")
    func redis() {
        #expect(DatabaseLogin.from(dotenv: "REDIS_PASSWORD=null\n", scheme: "redis") == nil)
        #expect(DatabaseLogin.from(dotenv: "REDIS_PASSWORD=hunter2\n", scheme: "redis") == DatabaseLogin(password: "hunter2"))
        #expect(DatabaseLogin.from(dotenv: "REDIS_URL=redis://default:hunter2@localhost:6379/0\n", scheme: "redis")
            == DatabaseLogin(user: "default", password: "hunter2", database: "0"))
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
