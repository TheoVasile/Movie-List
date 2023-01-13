//
//  DataAccess.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import Foundation
import SwiftUI
import SQLite

class DataAccess {
    
    let db_name = "movies"
    
    let listName = Expression<String>("list_name")
    let movieName = Expression<String>("movie_name")
    let movieYear = Expression<Int64>("movie_year")
    let movieRank = Expression<Int64>("movie_rank")
    
    func addMovie(list: String, name: String, year: Int64, rank: Int64) -> Int64 {
        /**
         Inserts a movies into a given <list> with the specified <name>, <year>, and <rank>
         */
        do {
            let db = try Connection(fileName())
            
            let movies = Table(db_name)

            let rowId = try db.run(movies.insert(
                listName <- list,
                movieName <- name,
                movieYear <- year,
                movieRank <- rank))
            
            return rowId
            
        } catch {
            print("ERROR: \(error)")
        }
        return -1
    }
    
    func getMovieList(list: String) -> Array<String>?{
        /**
        Returns a list containing the names of all the movies in the given list
         */
        var moviesFromList = [String]()
        do {
            let db = try Connection(fileName())
            let movies = Table(db_name)
            for movie in try db.prepare(movies) {
                if movie[listName] == list {
                    moviesFromList.append(movie[movieName])
                }
            }
            
            return moviesFromList
        } catch {
            print("ERROR: \(error)")
        }
        return nil
    }
    
    func getLists() -> Array<String>?{
        /**
        Returns a list containing the names of each unique list stored in the database
         */
        var movieLists = [String]()
        do {
            let db = try Connection(fileName())
            let movies = Table(db_name)
            for movie in try db.prepare(movies) {
                if !movieLists.contains(movie[listName]){
                    movieLists.append(movie[listName])
                }
            }
            
            return movieLists
        } catch {
            print("ERROR: \(error)")
        }
        return nil
    }
    
    func fileName() -> String {
        let path = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true
        ).first!
        
        let name = "\(path)/db.sqlite3";
        return name;
    }
    
    func initTables() {
        do {
            let db = try Connection(fileName())
            
            try initMoviesTable(db: db)
            
        } catch {
            print("ERROR: \(error)")
        }
    }
    
    func dropTables() {
        do {
            let db = try Connection(fileName())
            
            let movies = Table(db_name)
            try db.run(movies.drop(ifExists: true));
            
        } catch {
            print("ERROR: \(error)")
        }
    }
    
    private func initMoviesTable(db: Connection) throws {
        let movies = Table(db_name)
        
        try db.run(movies.create(ifNotExists: true) { t in
            t.column(listName, primaryKey: true)
            t.column(movieName)
            t.column(movieYear)
            t.column(movieRank)
        })
    }
    
}
