//
//  RealmResultsCache.swift
//  redbooth-ios-sdk
//
//  Created by Isaac Roldan on 4/8/15.
//  Copyright © 2015 Redbooth Inc.
//

import Foundation
import RealmSwift

enum RealmCacheUpdateType: String {
    case Move
    case Update
    case Insert
}

protocol RealmResultsCacheDelegate: class {
    func didInsertSection<T: Object>(section: Section<T>, index: Int)
    func didDeleteSection<T: Object>(section: Section<T>, index: Int)
    func didInsert<T: Object>(object: T, indexPath: NSIndexPath)
    func didUpdate<T: Object>(object: T, oldIndexPath: NSIndexPath, newIndexPath: NSIndexPath, changeType: RealmResultsChangeType)
    func didDelete<T: Object>(object: T, indexPath: NSIndexPath)
}

/**
The Cache is responsible to store a copy of the current objects used by the RRC obtained by the original request.
It has an Array of sections where the objects are stored, always filtered and sorted by the request.

The array of sections is constructed depending on the SectionKeyPath given in the RRC creation.

When interacting with the cache is important to do it always in this order:
Taking into account that a MOVE is not an update but a pair of delete/insert operations.

- Deletions
- Insertions
- Updates (Only for objects that won't change position)

:important: always call the three methods, the operations are commited at the end
so calling only `delete` will change the cache but not call the delegate.
*/
class RealmResultsCache<T: Object> {
    var request: RealmRequest<T>
    var sectionKeyPath: String? = ""
    var sections: [Section<T>] = []
    let defaultKeyPathValue = "default"
    weak var delegate: RealmResultsCacheDelegate?
    
    var temporalDeletions: [T] = []
    var temporalDeletionsIndexPath: [T: NSIndexPath] = [:]
    
    
    //MARK: Initializer
    init(request: RealmRequest<T>, sectionKeyPath: String?) {
        self.request = request
        self.sectionKeyPath = sectionKeyPath
    }
    

    //MARK: Population
    func populateSections(objects: [T]) {
        for object in objects {
            let section = getOrCreateSection(object)
            section.insertSorted(object)
        }
    }
    
    func reset(objects: [T]) {
        sections.removeAll()
        populateSections(objects)
    }
    
    //MARK: Actions
    
    func insert(objects: [T]) {
        let mirrorsArray = sortedMirrors(objects)
        for object in mirrorsArray {
            let section = getOrCreateSection(object) //Calls the delegate when there is an insertion
            let rowIndex = section.insertSorted(object)
            let sectionIndex = indexForSection(section)!
            let indexPath = NSIndexPath(forRow: rowIndex, inSection: sectionIndex)
            
            // If the object was not deleted previously, it is just an INSERT.
            if !temporalDeletions.contains(object) {
                delegate?.didInsert(object, indexPath: indexPath)
                continue
            }
            
            // If the object was already deleted, then is a MOVE, and the insert/deleted
            // should be wrapped in only one operation to the delegate
            let oldIndexPath = temporalDeletionsIndexPath[object]
            delegate?.didUpdate(object, oldIndexPath: oldIndexPath!, newIndexPath: indexPath, changeType: RealmResultsChangeType.Move)
            let index = temporalDeletions.indexOf(object)
            temporalDeletions.removeAtIndex(index!)
            temporalDeletionsIndexPath.removeValueForKey(object)
        }
        
        // The remaining objects, not MOVED or INSERTED, are DELETES, and must be deleted at the end
        for object in temporalDeletions {
            let oldIndexPath = temporalDeletionsIndexPath[object]
            delegate?.didDelete(object, indexPath: oldIndexPath!)
        }
        temporalDeletions.removeAll()
        temporalDeletionsIndexPath.removeAll()
    }
    
    func delete(objects: [T]) {
        var outdated: [T] = []
        for object in objects {
            guard let section = sectionForOutdateObject(object) else { continue }
            let index = section.indexForOutdatedObject(object)
            if index == -1 { continue }
            outdated.append(section.objects.objectAtIndex(index) as! T)
        }
        
        let mirrorsArray = sortedMirrors(outdated).reverse() as [T]
        
        for object in mirrorsArray {
            let section = sectionForOutdateObject(object)!
            let index = section.deleteOutdatedObject(object)
            let indexPath = NSIndexPath(forRow: index, inSection: indexForSection(section)!)
            
            temporalDeletions.append(object)
            temporalDeletionsIndexPath[object] = indexPath
            
            if section.objects.count == 0 {
                sections.removeAtIndex(indexPath.section)
                delegate?.didDeleteSection(section, index: indexPath.section)
            }
        }
    }
    
    
    func update(objects: [T]) {
        for object in objects {
            guard let oldSection = sectionForOutdateObject(object) else { continue }
            let oldSectionIndex = indexForSection(oldSection)!
            let oldIndexRow = oldSection.indexForOutdatedObject(object)
            
            if oldIndexRow == -1 {
                insert([object])
                continue
            }
            
            let oldIndexPath = NSIndexPath(forRow: oldIndexRow, inSection: oldSectionIndex)
            
            oldSection.deleteOutdatedObject(object)
            let newIndexRow = oldSection.insertSorted(object)
            let newIndexPath = NSIndexPath(forRow: newIndexRow, inSection: oldSectionIndex)
            delegate?.didUpdate(object, oldIndexPath: oldIndexPath, newIndexPath: newIndexPath, changeType: .Update)
        }
    }

    
    //MARK: Create
    
    private func createNewSection(keyPath: String, notifyDelegate: Bool = true) -> Section<T> {
        let newSection = Section<T>(keyPath: keyPath, sortDescriptors: request.sortDescriptors.map(toNSSortDescriptor))
        sections.append(newSection)
        sortSections()
        let index = indexForSection(newSection)!
        if notifyDelegate {
            delegate?.didInsertSection(newSection, index: index)
        }
        return newSection
    }
    
    
    //MARK: Retrieve
    private func getOrCreateSection(object: T) -> Section<T> {
        let key = keyPathForObject(object)
        let section = sectionForKeyPath(key)
        return section != nil ? section! : createNewSection(key)
    }
    
    private func sectionForKeyPath(keyPath: String, create: Bool = true) -> Section<T>? {
        let section = sections.filter{$0.keyPath == keyPath}
        return section.first
    }
    
    private func sectionForOutdateObject(object: T) -> Section<T>? {
        for section in sections {
            if section.indexForOutdatedObject(object) != -1 {
                return section
            }
        }
        let key = keyPathForObject(object)
        return sectionForKeyPath(key)
    }
    
    
    //MARK: Indexes
    
    private func indexForSection(section: Section<T>) -> Int? {
        return sections.indexOf(section)
    }
    
    
    //MARK: Helpers
    
    /**
    Given an object this method returns the type of update that this object will 
    perform in the cache: .Move, .Update or .Insert
    
    :param: object Object to update
    
    :returns: Type of the update needed for the given object
    */
    func updateType(object: T) -> RealmCacheUpdateType {
        //Sections
        guard let oldSection = sectionForOutdateObject(object) else { return .Insert }
        guard let newSection = sectionForKeyPath(keyPathForObject(object)) else { return .Insert }
        
        //OutdatedCopy
        guard let outdatedCopy = oldSection.outdatedObject(object) else { return .Insert }
        
        //Indexes
        let oldIndexRow = oldSection.delete(outdatedCopy)
        if oldIndexRow == -1 { return .Insert }
        let newIndexRow = newSection.insertSorted(object)

        //Restore
        newSection.delete(object)
        oldSection.insertSorted(outdatedCopy)
        
        if oldSection == newSection && oldIndexRow == newIndexRow {
            return .Update
        }
        return .Move
    }
    
    func keyPathForObject(object: T) -> String {
        var keyPathValue = defaultKeyPathValue
        if let keyPath = sectionKeyPath {
            if keyPath.isEmpty { return  defaultKeyPathValue }
            if NSThread.currentThread().isMainThread {
                keyPathValue = String(object.valueForKeyPath(keyPath)!)
            }
            else {
                dispatch_sync(dispatch_get_main_queue()) {
                    keyPathValue = String(object.valueForKeyPath(keyPath)!)
                }
            }
        }
        return keyPathValue
    }
    
    /**
    Sort an array of objects (mirrors of the original realm objects)
    Using the SortDescriptors of the RealmRequest of the RRC.
    
    :param: mirrors Objects to sort
    
    :returns: sorted Array<T>
    */
    private func sortedMirrors(mirrors: [T]) -> [T] {
        let mutArray = NSMutableArray(array: mirrors)
        let sorts = request.sortDescriptors.map(toNSSortDescriptor)
        mutArray.sortUsingDescriptors(sorts)
        return mutArray as AnyObject as! [T]
    }

    /**
    Sort the sections using the Given KeyPath
    */
    private func sortSections() {
        sections.sortInPlace { $0.keyPath.localizedCaseInsensitiveCompare($1.keyPath) == NSComparisonResult.OrderedAscending }
    }
    
    /**
    Transforms a SortDescriptor into a NSSortDescriptor that can be applied to NSMutableArray
    
    :param: sort SortDescriptor object
    
    :returns: NSSortDescriptor
    */
    private func toNSSortDescriptor(sort: SortDescriptor) -> NSSortDescriptor {
        return NSSortDescriptor(key: sort.property, ascending: sort.ascending)
    }
}
