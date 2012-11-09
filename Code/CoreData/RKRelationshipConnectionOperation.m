//
//  RKRelationshipConnectionOperation.m
//  RestKit
//
//  Created by Blake Watters on 7/12/12.
//  Copyright (c) 2012 RestKit. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import <CoreData/CoreData.h>
#import "RKRelationshipConnectionOperation.h"
#import "RKEntityMapping.h"
#import "RKLog.h"
#import "RKManagedObjectCaching.h"
#import "RKDynamicMappingMatcher.h"
#import "RKErrors.h"
#import "RKObjectUtilities.h"

// Set Logging Component
#undef RKLogComponent
#define RKLogComponent RKlcl_cRestKitCoreData

static id RKMutableSetValueForRelationship(NSRelationshipDescription *relationship)
{
    if (! [relationship isToMany]) return nil;
    return [relationship isOrdered] ? [NSMutableOrderedSet orderedSet] : [NSMutableSet set];
}

@interface RKRelationshipConnectionOperation ()
@property (nonatomic, strong, readwrite) NSManagedObject *managedObject;
@property (nonatomic, strong, readwrite) RKConnectionMapping *connectionMapping;
@property (nonatomic, strong, readwrite) id<RKManagedObjectCaching> managedObjectCache;
@property (nonatomic, strong, readwrite) NSError *error;
@property (nonatomic, strong, readwrite) id connectedValue;

// Helpers
@property (weak, nonatomic, readonly) NSManagedObjectContext *managedObjectContext;

@end

@implementation RKRelationshipConnectionOperation


- (id)initWithManagedObject:(NSManagedObject *)managedObject connectionMapping:(RKConnectionMapping *)connectionMapping managedObjectCache:(id<RKManagedObjectCaching>)managedObjectCache
{
    NSParameterAssert(managedObject);
    NSAssert([managedObject isKindOfClass:[NSManagedObject class]], @"Relationship connection requires an instance of NSManagedObject");
    NSParameterAssert(connectionMapping);
    NSParameterAssert(managedObjectCache);
    self = [self init];
    if (self) {
        self.managedObject = managedObject;
        self.connectionMapping = connectionMapping;
        self.managedObjectCache = managedObjectCache;
    }

    return self;
}

- (NSManagedObjectContext *)managedObjectContext
{
    return self.managedObject.managedObjectContext;
}

- (NSManagedObject *)findOneConnectedWithSourceValue:(id)sourceValue
{
    NSAssert(self.managedObjectContext, @"Cannot lookup objects with a nil managedObjectContext");
    return [self.managedObjectCache findInstanceOfEntity:self.connectionMapping.relationship.destinationEntity
                                 withPrimaryKeyAttribute:self.connectionMapping.destinationKeyPath
                                                   value:sourceValue
                                  inManagedObjectContext:self.managedObjectContext];
}

- (id)relationshipValueWithConnectionResult:(id)result
{
    // TODO: Replace with use of object mapping engine for type conversion

    // NOTE: This is a nasty hack to work around the fact that NSOrderedSet does not support key-value
    // collection operators. We try to detect and unpack a doubly wrapped collection
    if ([self.connectionMapping.relationship isToMany] && RKObjectIsCollectionOfCollections(result)) {
        id mutableSet = RKMutableSetValueForRelationship(self.connectionMapping.relationship);
        for (id<NSFastEnumeration> enumerable in result) {
            for (id object in enumerable) {
                [mutableSet addObject:object];
            }
        }

        return mutableSet;
    }

    if ([self.connectionMapping.relationship isToMany]) {
        if ([result isKindOfClass:[NSArray class]]) {
            if ([self.connectionMapping.relationship isOrdered]) {
                return [NSOrderedSet orderedSetWithArray:result];
            } else {
                return [NSSet setWithArray:result];
            }
        } else if ([result isKindOfClass:[NSSet class]]) {
            if ([self.connectionMapping.relationship isOrdered]) {
                return [NSOrderedSet orderedSetWithSet:result];
            } else {
                return result;
            }
        } else if ([result isKindOfClass:[NSOrderedSet class]]) {
            if ([self.connectionMapping.relationship isOrdered]) {
                return result;
            } else {
                return [(NSOrderedSet *)result set];
            }
        } else {
            if ([self.connectionMapping.relationship isOrdered]) {
                return [NSOrderedSet orderedSetWithObject:result];
            } else {
                return [NSSet setWithObject:result];
            }
        }
    }

    return result;
}

- (NSMutableSet *)findAllConnectedWithSourceValue:(id)sourceValue
{
    NSMutableSet *result = [NSMutableSet set];

    id values = nil;
    if ([sourceValue conformsToProtocol:@protocol(NSFastEnumeration)]) {
        values = sourceValue;
    } else {
        values = [NSArray arrayWithObject:sourceValue];
    }

    for (id value in values) {
        NSAssert(self.managedObjectContext, @"Cannot lookup objects with a nil managedObjectContext");
        NSArray *objects = [self.managedObjectCache findInstancesOfEntity:self.connectionMapping.relationship.destinationEntity
                                                  withPrimaryKeyAttribute:self.connectionMapping.destinationKeyPath
                                                                    value:value
                                                   inManagedObjectContext:self.managedObjectContext];
        [result addObjectsFromArray:objects];
    }
    return result;
}

- (BOOL)isToMany
{
    return self.connectionMapping.relationship.isToMany;
}

- (BOOL)checkMatcher
{
    if (!self.connectionMapping.matcher) {
        return YES;
    } else {
        return [self.connectionMapping.matcher matches:self.managedObject];
    }
}

- (id)findConnected
{
    if ([self checkMatcher]) {
        id connectionResult = nil;
        if ([self.connectionMapping isForeignKeyConnection]) {
            BOOL isToMany = [self isToMany];
            id sourceValue = [self.managedObject valueForKey:self.connectionMapping.sourceKeyPath];
            if (isToMany) {
                connectionResult = [self findAllConnectedWithSourceValue:sourceValue];
            } else {
                connectionResult = [self findOneConnectedWithSourceValue:sourceValue];
            }
        } else if ([self.connectionMapping isKeyPathConnection]) {
            connectionResult = [self.managedObject valueForKeyPath:self.connectionMapping.sourceKeyPath];
        } else {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                           reason:[NSString stringWithFormat:@"%@ Attempted to establish a relationship using a mapping"
                                                   "specifies neither a foreign key or a key path connection: %@",
                                                   NSStringFromClass([self class]), self.connectionMapping]
                                         userInfo:nil];
        }

        return [self relationshipValueWithConnectionResult:connectionResult];
    } else {
        return nil;
    }
}

- (void)connectRelationship
{
    NSString *relationshipName = self.connectionMapping.relationship.name;
    RKLogTrace(@"Connecting relationship '%@' with mapping: %@", relationshipName, self.connectionMapping);
    [self.managedObjectContext performBlockAndWait:^{
        self.connectedValue = [self findConnected];
        [self.managedObject setValue:self.connectedValue forKeyPath:relationshipName];
        RKLogDebug(@"Connected relationship '%@' to object '%@'", relationshipName, self.connectedValue);
    }];
}

- (void)main
{
    if (self.isCancelled) return;
    [self connectRelationship];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@:%p %@ in %@ using %@>",
            [self class], self, self.connectionMapping, self.managedObjectContext, self.managedObjectCache];
}

@end
