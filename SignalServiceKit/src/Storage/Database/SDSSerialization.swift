//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation
import GRDBCipher
import SignalCoreKit

@objc
public class SDSSerialization: NSObject {

    // MARK: - Save (Upsert)

    class func save(entity: SDSSerializable,
                    transaction: GRDBWriteTransaction) {
        let serializer = entity.serializer
        let tableMetadata = serializer.serializableColumnTableMetadata()
        let database = transaction.database

        do {
            if try exists(tableMetadata: tableMetadata,
                          uniqueIdColumnName: serializer.uniqueIdColumnName(),
                          uniqueIdColumnValue: serializer.uniqueIdColumnValue(),
                          database: database) {
                try update(entity: entity,
                           uniqueIdColumnName: serializer.uniqueIdColumnName(),
                           uniqueIdColumnValue: serializer.uniqueIdColumnValue(),
                           database: database)
            } else {
                try insert(entity: entity,
                           database: database)
            }
        } catch let error {
            // TODO:
            owsFail("Write failed: \(error)")
        }
    }

    public class func insert(entity: SDSSerializable,
                             database: Database) throws {
        let serializer = entity.serializer
        let tableMetadata = serializer.serializableColumnTableMetadata()
        let tableName = tableMetadata.tableName
        let columnNames: [String] = serializer.insertColumnNames()
        let columnValues: [DatabaseValueConvertible] = serializer.insertColumnValues()
        let columnsSQL = columnNames.map { $0.quotedDatabaseIdentifier }.joined(separator: ", ")
        let valuesSQL = databaseQuestionMarks(count: columnValues.count)
        let sql: String = "INSERT INTO \(tableName.quotedDatabaseIdentifier) (\(columnsSQL)) VALUES (\(valuesSQL))"

        let statement = try database.cachedUpdateStatement(sql: sql)
        guard let arguments = StatementArguments(columnValues) else {
            owsFail("Could not convert values.")
        }
        // TODO: We could use setArgumentsWithValidation for more safety.
        statement.unsafeSetArguments(arguments)
        try statement.execute()
    }

    fileprivate class func update(entity: SDSSerializable,
                                  uniqueIdColumnName: String,
                                  uniqueIdColumnValue: DatabaseValueConvertible,
                                  database: Database) throws {
        let serializer = entity.serializer
        let tableMetadata = serializer.serializableColumnTableMetadata()
        let tableName = tableMetadata.tableName
        let columnNames: [String] = serializer.updateColumnNames()
        let columnValues = serializer.updateColumnValues()
        let updateSQL = columnNames.map { "\($0.quotedDatabaseIdentifier)=?" }.joined(separator: ", ")
        let whereSQL = "\(uniqueIdColumnName.quotedDatabaseIdentifier)=?"
        let sql: String = "UPDATE \(tableName.quotedDatabaseIdentifier) SET \(updateSQL) WHERE \(whereSQL)"

        let statement = try database.cachedUpdateStatement(sql: sql)
        guard let arguments = StatementArguments(columnValues + [uniqueIdColumnValue]) else {
            owsFail("Could not convert values.")
        }
        // TODO: We could use setArgumentsWithValidation for more safety.
        statement.unsafeSetArguments(arguments)
        try statement.execute()
    }

    fileprivate class func exists(tableMetadata: SDSTableMetadata,
                                  uniqueIdColumnName: String,
                                  uniqueIdColumnValue: DatabaseValueConvertible,
                                  database: Database) throws -> Bool {

        let query = existsQuery(tableMetadata: tableMetadata,
                                uniqueIdColumnName: uniqueIdColumnName)
        let statement = try database.cachedSelectStatement(sql: query)
        guard let arguments = StatementArguments([uniqueIdColumnValue]) else {
            owsFail("Could not convert values.")
        }
        // TODO: We could use setArgumentsWithValidation for more safety.
        statement.unsafeSetArguments(arguments)
        let sqliteStatement: SQLiteStatement = statement.sqliteStatement

        switch sqlite3_step(sqliteStatement) {
        case SQLITE_DONE:
            Logger.verbose("SQLITE_DONE")
            return false
        case SQLITE_ROW:
            Logger.verbose("SQLITE_ROW")
            return true
        case let code:
            // TODO: ?
            owsFailDebug("Code: \(code)")
            return false
        }
    }

    fileprivate class func existsQuery(tableMetadata: SDSTableMetadata,
                                       uniqueIdColumnName: String) -> String {
        let tableName = tableMetadata.tableName
        return "SELECT 1 FROM \(tableName.quotedDatabaseIdentifier) WHERE \(uniqueIdColumnName.quotedDatabaseIdentifier)=?"
    }

    // MARK: - Remove

    class func delete(entity: SDSSerializable,
                    transaction: GRDBWriteTransaction) {
        let serializer = entity.serializer
        let database = transaction.database

        do {
            try delete(entity: entity,
                       uniqueIdColumnName: serializer.uniqueIdColumnName(),
                       uniqueIdColumnValue: serializer.uniqueIdColumnValue(),
                       database: database)
        } catch let error {
            // TODO:
            owsFail("Write failed: \(error)")
        }
    }

    fileprivate class func delete(entity: SDSSerializable,
                                  uniqueIdColumnName: String,
                                  uniqueIdColumnValue: DatabaseValueConvertible,
                                  database: Database) throws {
        let serializer = entity.serializer
        let tableMetadata = serializer.serializableColumnTableMetadata()
        let tableName = tableMetadata.tableName
        let whereSQL = "\(uniqueIdColumnName.quotedDatabaseIdentifier)=?"
        let sql: String = "DELETE FROM \(tableName.quotedDatabaseIdentifier) WHERE \(whereSQL)"

        let statement = try database.cachedUpdateStatement(sql: sql)
        guard let arguments = StatementArguments([uniqueIdColumnValue]) else {
            owsFail("Could not convert values.")
        }
        // TODO: We could use setArgumentsWithValidation for more safety.
        statement.unsafeSetArguments(arguments)
        try statement.execute()
    }

    // MARK: - Fetch (Read)

    // Add: fetchOne, fetchCursor, fetchWhere, etc.
    public class func fetchAll<T>(tableMetadata: SDSTableMetadata,
                                  uniqueIdColumnName: String,
                                  transaction: GRDBReadTransaction,
                                  deserialize: (SelectStatement) throws -> T) -> [T] {
        Logger.verbose("")

        let database = transaction.database

        // TODO: This assumes the table has already been made.

        do {
            let columnNames: [String] = tableMetadata.selectColumnNames
            let columnsSQL: String = columnNames.map { $0.quotedDatabaseIdentifier }.joined(separator: ", ")
            let tableName: String = tableMetadata.tableName
            // TODO: ORDER BY?
            let query: String = "SELECT \(columnsSQL) FROM \(tableName.quotedDatabaseIdentifier)"
            let statement: SelectStatement = try database.cachedSelectStatement(sql: query)

            let sqliteStatement: SQLiteStatement = statement.sqliteStatement

            var entities = [T]()
            var done = false
            repeat {
                switch sqlite3_step(sqliteStatement) {
                case SQLITE_DONE:
                    Logger.verbose("SQLITE_DONE")
                    done = true
                    break
                case SQLITE_ROW:
                    Logger.verbose("SQLITE_ROW")
                    let entity = try deserialize(statement)
                    entities.append(entity)
                    continue
                //                    return true
                case let code:
                    // TODO: ?
                    owsFailDebug("Code: \(code)")
                    // TODO: Rework error handling.
                    //                throw DatabaseError(resultCode: code, message: statement.database.lastErrorMessage, sql: statement.sql, arguments: statement.arguments)
                    done = true
                    break
                }
            } while !done

            return entities
        } catch let error {
            // TODO:
            //            throw DatabaseError(resultCode: code, message: statement.database.lastErrorMessage, sql: statement.sql, arguments: statement.arguments)
            owsFail("Read failed: \(error)")
        }
    }
}
