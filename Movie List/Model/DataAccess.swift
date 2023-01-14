//
//  DataAccess.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import Foundation
import SwiftUI
import SQLite

struct DataAccess {
    
    let db_movies = "movies"
    let db_lists = "lists"
    
    let listName = Expression<String>("list_name")
    let id = Expression<Int64>("id")
    let movieName = Expression<String>("movie_name")
    let movieYear = Expression<Int64>("movie_year")
    let movieRank = Expression<Int64>("movie_rank")
    
    init() {
        initTables()
    }
    
    func addMovie(list: String, name: String, year: Int64, rank: Int64) -> Int64 {
        /**
         Inserts a movie into a given <list> with the specified <name>, <year>, and <rank>
         */
        do {
            let db = try Connection(fileName())
            
            var id_ = getListId(list: list)
            if id_ < 0 {
                id_ = getNewId()
            }
            
            let movies = Table(db_movies)
            let lists = Table(db_lists)

            try db.run(lists.insert(
                listName <- list,
                id <- id_))
            
            let rowId = try db.run(movies.insert(
                id <- id_,
                movieName <- name,
                movieYear <- year,
                movieRank <- rank))
            
            return rowId
            
        } catch {
            print("ERROR: \(error)")
        }
        return -1
    }
    
    func addList(list: String) -> Int64{
        /**
         Create a new movies list with no movies
         */
        do {
            let db = try Connection(fileName())
            let id_ = getNewId()
            
            let lists = Table(db_lists)
            
            let rowId = try db.run(lists.insert(
                listName <- list,
                id <- id_
            ))
            return rowId
        } catch {
            print("ERROR: \(error)")
        }
        return -1
    }
    
    func deleteList(list: String) -> Int64{
        /**
         Removes a list and all its movies from the database, returns -1 on failure, 0 otherwise
         */
        do {
            let db = try Connection(fileName())
            let id_ = getListId(list: list)
            
            let lists = Table(db_lists)
            let movies = Table(db_movies)
            
            let deleted_movies = movies.filter(id == id_)
            try db.run(deleted_movies.delete())
            
            let deleted_list = lists.filter(id == id_)
            try db.run(deleted_list.delete())
            
            return 0
        } catch{
            print("ERROR: \(error)")
        }
        return -1
    }
    
    func deleteMovie(list: String, name: String, year: Int64?) -> Int64 {
        /**
         Removes a movie from a list, returns -1 on failure, 0 otherwise
         */
        do {
            let db = try Connection(fileName())
            let id_ = getListId(list: list)
            
            let movies = Table(db_movies)
            
            var deleted_movie = movies.filter(id == id_ && movieName == name)
            if year != nil{
                deleted_movie = movies.filter(id == id_ && movieName == name && movieYear == year ?? 0)
            }
            try db.run(deleted_movie.delete())
            
            return 0
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
            let id_ = getListId(list: list)
            let movies = Table(db_movies)
            let rowIterator = try db.prepareRowIterator(movies)
            for movie in try Array(rowIterator) {
                if movie[id] == id_ {
                    moviesFromList.append(movie[movieName])
                }
            }
            
            return moviesFromList
        } catch {
            print("ERROR: \(error)")
        }
        return nil
    }
    
    func getNewId() -> Int64{
        /**
         Return an id that doesnt exist in either table
         Return -1 if there is an error
         */
        do {
            var id_: Int64 = 0
            let db = try Connection(fileName())
            let lists = Table(db_lists)
            let rowIterator = try db.prepareRowIterator(lists)
            for list_ in try Array(rowIterator) {
                if list_[id] > id_{
                    id_ += 1
                }
            }
            return id_ + 1
        } catch {
            print("ERROR: \(error)")
        }
        return -1
    }
    
    func getListId(list: String) -> Int64{
        /**
         Return the corresponding id of a list
         */
        do {
            let db = try Connection(fileName())
            let lists = Table(db_lists)
            let rowIterator = try db.prepareRowIterator(lists)
            for list_ in try Array(rowIterator) {
                if list_[listName] == list{
                    return list_[id]
                }
            }
        } catch {
            print("ERROR: \(error)")
        }
        return -1
    }
    
    func getLists() -> Array<String>?{
        /**
        Returns a list containing the names of each unique list stored in the database
         */
        var movieLists = [String]()
        do {
            let db = try Connection(fileName())
            let lists = Table(db_lists)
            for list in try db.prepare(lists) {
                if !movieLists.contains(list[listName]){
                    movieLists.append(list[listName])
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
            
            let movies = Table(db_movies)
            let lists = Table(db_lists)
            
            try db.run(movies.drop(ifExists: true))
            try db.run(lists.drop(ifExists: true))
            
            print("Dropped tables")
            
        } catch {
            print("ERROR: \(error)")
        }
    }
    
    private func initMoviesTable(db: Connection) throws {
        let movies = Table(db_movies)
        let lists = Table(db_lists)
        
        try db.run(movies.create(ifNotExists: true) { t in
            t.column(id)
            t.column(movieName)
            t.column(movieYear)
            t.column(movieRank)
        })
        
        try db.run(lists.create(ifNotExists: true) { t in
            t.column(listName)
            t.column(id)
        })
    }
    
}
