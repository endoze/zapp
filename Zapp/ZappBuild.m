//
//  ZappBuild.m
//  Zapp
//
//  Created by Jim Puls on 8/5/11.
//  Licensed to Square, Inc. under one or more contributor license agreements.
//  See the LICENSE file distributed with this work for the terms under
//  which Square, Inc. licenses this file to you.

#import "ZappBuild.h"
#import "ZappMessageController.h"
#import "ZappSimulatorController.h"


#define UPDATE_PHASE_PROGRESS 0.1
#define BUILD_PHASE_PROGRESS 0.1


@interface ZappBuild ()

@property (nonatomic, strong, readwrite) NSArray *logLines;
@property (nonatomic, strong) ZappSimulatorController *simulatorController;
@property (nonatomic, copy) void (^completionBlock)(void);
@property (nonatomic, strong, readwrite) NSFetchRequest *previousBuildFetchRequest;
@property (nonatomic, strong, readwrite) NSFetchRequest *previousSuccessfulBuildFetchRequest;

@property (readonly, getter = isRunning) BOOL running;

- (void)appendLogLines:(NSString *)newLogLinesString;
- (NSURL *)appSupportURLWithExtension:(NSString *)extension;
- (void)runSimulatorWithAppPath:(NSString *)appPath initialSkip:(NSInteger)initialSkip failureCount:(NSInteger)initialFailureCount startsWithRetry:(BOOL)startsWithRetry;
- (void)callCompletionBlockWithStatus:(int)exitStatus;

@end

@implementation ZappBuild

@dynamic branch;
@dynamic endTimestamp;
@dynamic latestRevision;
@dynamic platform;
@dynamic repository;
@dynamic scheme;
@dynamic startTimestamp;
@dynamic status;

@synthesize commitLog;
@synthesize logLines;
@synthesize previousBuildFetchRequest;
@synthesize previousSuccessfulBuildFetchRequest;
@synthesize simulatorController;
@synthesize completionBlock;
@synthesize progress;

#pragma mark Accessors

- (BOOL)isRunning;
{
    @synchronized(self) {
        return self.status == ZappBuildStatusRunning;
    }
}

- (NSString *)commitLog;
{
    if (!commitLog) {
        [self.repository runCommand:GitCommand withArguments:[NSArray arrayWithObjects:@"log", @"--pretty=oneline", @"-1", self.latestRevision, nil] completionBlock:^(NSString *newLog) {
            self.commitLog = newLog;
        }];
    }
    return commitLog;
}

#pragma mark Derived properties

- (NSURL *)appSupportURLWithExtension:(NSString *)extension;
{
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSArray *supportURLs = [fileManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask];
    NSURL *storageURL = [[supportURLs objectAtIndex:0] URLByAppendingPathComponent:[[NSRunningApplication currentApplication] localizedName]];
    NSString *uniqueID = [[[[self objectID] URIRepresentation] path] stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    return [storageURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", uniqueID, extension]];
}

- (NSURL *)buildLogURL;
{
    return [self appSupportURLWithExtension:@"log"];
}

- (NSURL *)buildVideoURL;
{
    return [self appSupportURLWithExtension:@"mov"];
}

- (NSString *)feedDescription;
{
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setTimeStyle:NSDateFormatterMediumStyle];
    [dateFormatter setDateStyle:NSDateFormatterMediumStyle];
    
    NSString *revision = self.abbreviatedLatestRevision;
    NSString *statusDescription = [self.statusDescription lowercaseString];
    
    return [NSString stringWithFormat:@"Built %@ on %@: %@", revision, [dateFormatter stringFromDate:self.startTimestamp], statusDescription];
}

+ (NSSet *)keyPathsForValuesAffectingFeedDescription;
{
    return [NSSet setWithObjects:@"startTimestamp", @"status", @"latestRevision", nil];
}

- (NSString *)description;
{
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setTimeStyle:NSDateFormatterMediumStyle];
    [dateFormatter setDateStyle:NSDateFormatterMediumStyle];
    
    NSString *revision = self.abbreviatedLatestRevision;
    
    if (self.status == ZappBuildStatusPending) {
        return [NSString stringWithFormat:@"%@: %@", self.statusDescription, revision];
    }
    
    return [NSString stringWithFormat:@"%@: %@ on %@", self.statusDescription, revision, [dateFormatter stringFromDate:self.startTimestamp]];
}

+ (NSSet *)keyPathsForValuesAffectingDescription;
{
    return [NSSet setWithObjects:@"startTimestamp", @"status", @"latestRevision", nil];
}

- (NSString *)activityTitle;
{
    return [NSString stringWithFormat:@"%@: %@", self.repository.name, self.abbreviatedLatestRevision];
}

+ (NSSet *)keyPathsForValuesAffectingActivityTitle;
{
    return [NSSet setWithObjects:@"repository.name", @"abbreviatedLatestRevision", nil];
}

- (NSArray *)logLines;
{
    [self willAccessValueForKey:@"logLines"];
    if (!logLines) {
        NSString *path = self.buildLogURL.path;
        [[ZappRepository sharedBackgroundQueue] addOperationWithBlock:^() {
            NSString *fileContents = [NSString stringWithContentsOfFile:path usedEncoding:NULL error:NULL];
            if (!fileContents) {
                return;
            }

            NSArray *newLogLines = [fileContents componentsSeparatedByString:@"\n"];
            [[NSOperationQueue mainQueue] addOperationWithBlock:^() {
                self.logLines = newLogLines;
            }];
        }];
    }
    [self didAccessValueForKey:@"logLines"];
    return logLines;
}

- (NSString *)statusDescription;
{
    switch (self.status) {
        case ZappBuildStatusPending: return ZappLocalizedString(@"Pending");
        case ZappBuildStatusRunning: return ZappLocalizedString(@"Running");
        case ZappBuildStatusFailed: return ZappLocalizedString(@"Failed");
        case ZappBuildStatusSucceeded: return ZappLocalizedString(@"Success");
        default: break;
    }
    return nil;
}

+ (NSSet *)keyPathsForValuesAffectingStatusDescription;
{
    return [NSSet setWithObject:@"status"];
}

- (NSString *)abbreviatedLatestRevision;
{
    return [self.latestRevision substringToIndex:MIN(6, self.latestRevision.length)];
}

+ (NSSet *)keyPathsForValuesAffectingAbbreviatedLatestRevision;
{
    return [NSSet setWithObject:@"latestRevision"];
}

- (ZappBuild *)previousSuccessfulBuild;
{
    return [[self.managedObjectContext executeFetchRequest:self. previousSuccessfulBuildFetchRequest error:nil] lastObject];
}

- (NSFetchRequest *)previousSuccessfulBuildFetchRequest;
{
    if (!previousSuccessfulBuildFetchRequest) {
        NSFetchRequest *fetchRequest = [NSFetchRequest new];
        fetchRequest.entity = [NSEntityDescription entityForName:@"Build" inManagedObjectContext:self.managedObjectContext];
        
        fetchRequest.predicate = [NSPredicate predicateWithFormat:@"repository = %@ AND status = %d AND latestRevision != %@", self.repository, ZappBuildStatusSucceeded, self.latestRevision];
        fetchRequest.sortDescriptors = [NSArray arrayWithObject:[[NSSortDescriptor alloc] initWithKey:@"startTimestamp" ascending:NO]];
        fetchRequest.fetchLimit = 1;
        previousSuccessfulBuildFetchRequest = fetchRequest;
    }
    
    return previousSuccessfulBuildFetchRequest;
}

- (ZappBuild *)previousBuild;
{
    return [[self.managedObjectContext executeFetchRequest:self.previousBuildFetchRequest error:nil] lastObject];
}

- (NSFetchRequest *)previousBuildFetchRequest;
{
    if (!previousBuildFetchRequest) {
        NSFetchRequest *fetchRequest = [NSFetchRequest new];
        fetchRequest.entity = [NSEntityDescription entityForName:@"Build" inManagedObjectContext:self.managedObjectContext];
        
        fetchRequest.predicate = [NSPredicate predicateWithFormat:@"repository = %@ AND startTimestamp < %@ ", self.repository, self.startTimestamp];
        fetchRequest.sortDescriptors = [NSArray arrayWithObject:[[NSSortDescriptor alloc] initWithKey:@"startTimestamp" ascending:NO]];
        fetchRequest.fetchLimit = 1;
        previousBuildFetchRequest = fetchRequest;
    }
    
    return previousBuildFetchRequest;
}

#pragma mark ZappBuild

- (void)cancel;
{
    @synchronized (self) {
        if (self.status <= ZappBuildStatusRunning) {
            self.status = ZappBuildStatusFailed;
        }
    }
}

- (void)startWithCompletionBlock:(void (^)(void))theCompletionBlock;
{
    @synchronized (self) {
        self.status = ZappBuildStatusRunning;
    }
    self.startTimestamp = [NSDate date];
    self.scheme = self.repository.lastScheme;
    self.platform = self.repository.lastPlatform;
    self.branch = self.repository.lastBranch;
    self.completionBlock = theCompletionBlock;
    
    self.progress = 0.0;
    
    self.logLines = nil;
    ZappRepository *repository = self.repository;

    [[ZappRepository sharedBackgroundQueue] addOperationWithBlock:^() {
        NSString *errorOutput = nil;
        NSError *error = nil;
        [[NSFileManager defaultManager] createFileAtPath:self.buildLogURL.path contents:[NSData data] attributes:nil];
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingToURL:self.buildLogURL error:&error];
        NSString __block *appPath = nil;
        int exitStatus = 0;
        
        BOOL (^runGitCommandWithArguments)(NSArray *) = ^(NSArray *arguments) {
            NSString *errorOutput = nil;
            NSLog(@"running %@ %@", GitCommand, [arguments componentsJoinedByString:@" "]);
            int exitStatus = [repository runCommandAndWait:GitCommand withArguments:arguments standardInput:nil errorOutput:&errorOutput outputBlock:^(NSString *output, BOOL *stop) {
                [fileHandle writeData:[output dataUsingEncoding:NSUTF8StringEncoding]];
                [self appendLogLines:output];
                
                *stop = (self.status != ZappBuildStatusRunning);
            }];
            [fileHandle writeData:[errorOutput dataUsingEncoding:NSUTF8StringEncoding]];
            [self appendLogLines:errorOutput];
            if (exitStatus > 0 || !self.running) {
                [self callCompletionBlockWithStatus:exitStatus];
                return NO;
            }
            return YES;
        };
        
        // Step 1: Update
        if (!runGitCommandWithArguments([NSArray arrayWithObjects:GitFetchSubcommand, @"--prune", nil])) { return; }
        if (!runGitCommandWithArguments([NSArray arrayWithObjects:@"checkout", self.branch, nil])) { return; }
        if (!runGitCommandWithArguments([NSArray arrayWithObjects:@"submodule", @"sync", nil])) { return; }
        if (!runGitCommandWithArguments([NSArray arrayWithObjects:@"submodule", @"update", @"--init", nil])) { return; }
        [repository runCommandAndWait:GitCommand withArguments:[NSArray arrayWithObjects:@"rev-parse", @"HEAD", nil] standardInput:nil errorOutput:&errorOutput outputBlock:^(NSString *output, BOOL *stop) {
            [[NSOperationQueue mainQueue] addOperationWithBlock:^() {
                self.latestRevision = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                self.progress = UPDATE_PHASE_PROGRESS;
                
                *stop = !self.running;
            }];
        }];

        // Step 2: Build
        NSArray *buildArguments = [NSArray arrayWithObjects:@"-sdk", @"iphonesimulator", @"-scheme", self.scheme, @"VALID_ARCHS=i386", @"ARCHS=i386", @"ONLY_ACTIVE_ARCH=NO", @"DSTROOT=build", @"install", nil];
        NSRegularExpression *appPathRegex = [NSRegularExpression regularExpressionWithPattern:@"^SetMode .+? \"?([^\"]+\\.app)\"?$" options:NSRegularExpressionAnchorsMatchLines error:nil];
        exitStatus = [repository runCommandAndWait:XcodebuildCommand withArguments:buildArguments standardInput:nil errorOutput:&errorOutput outputBlock:^(NSString *output, BOOL *stop) {
            [fileHandle writeData:[output dataUsingEncoding:NSUTF8StringEncoding]];
            [self appendLogLines:output];
            [appPathRegex enumerateMatchesInString:output options:0 range:NSMakeRange(0, output.length) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
                appPath = [output substringWithRange:[result rangeAtIndex:1]];
                *stop = YES;
            }];
            *stop = !self.running;
        }];
        [fileHandle writeData:[errorOutput dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
        [self appendLogLines:errorOutput];
        if (exitStatus > 0 || !self.running) {
            [self callCompletionBlockWithStatus:exitStatus];
            return;
        }
        if (!appPath) {
            [self callCompletionBlockWithStatus:-1];
            return;
        }
        
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            self.progress = UPDATE_PHASE_PROGRESS + BUILD_PHASE_PROGRESS;
        }];
        
        // Step 3: Run
        [self runSimulatorWithAppPath:appPath initialSkip:0 failureCount:0 startsWithRetry:NO];
    }];
}

#pragma mark Private methods

- (void)runSimulatorWithAppPath:(NSString *)appPath initialSkip:(NSInteger)initialSkip failureCount:(NSInteger)initialFailureCount startsWithRetry:(BOOL)startsWithRetry;
{
    NSString __block *lastOutput = nil;
    NSInteger __block lastStartedScenario = initialSkip;
    NSInteger __block scenarioCount = 0;
    NSInteger __block failureCount = -1;
    NSRegularExpression *progressRegex = [NSRegularExpression regularExpressionWithPattern:@"BEGIN SCENARIO (\\d+)/(\\d+) " options:0 error:NULL];
    NSRegularExpression *failureRegex = [NSRegularExpression regularExpressionWithPattern:@"KIF TESTING FINISHED: (\\d+) failure" options:0 error:NULL];
    self.simulatorController = [ZappSimulatorController new];
    self.simulatorController.sdk = [self.platform objectForKey:@"version"];
    self.simulatorController.platform = [[self.platform objectForKey:@"device"] isEqualToString:@"ipad"] ? ZappSimulatorControllerPlatformiPad : ZappSimulatorControllerPlatformiPhone;
    self.simulatorController.appURL = [self.repository.localURL URLByAppendingPathComponent:appPath];
    self.simulatorController.simulatorOutputPath = self.buildLogURL.path;
    self.simulatorController.videoOutputURL = self.buildVideoURL;
    self.simulatorController.environment = [NSDictionary dictionaryWithObjectsAndKeys:@"1", @"KIF_AUTORUN", @"1", @"KIF_EXIT_ON_FAILURE", [NSString stringWithFormat:@"%ld", lastStartedScenario], @"KIF_INITIAL_SKIP_COUNT", nil];
    NSLog(@"starting simulator with skip count of %ld", lastStartedScenario);
    [self.simulatorController launchSessionWithOutputBlock:^(NSString *output, BOOL *stop) {
        [self appendLogLines:output];
        lastOutput = output;
        [progressRegex enumerateMatchesInString:output options:0 range:NSMakeRange(0, output.length) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
            lastStartedScenario = [[output substringWithRange:[result rangeAtIndex:1]] integerValue];
            scenarioCount = [[output substringWithRange:[result rangeAtIndex:2]] integerValue];
            [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                self.progress = (double)lastStartedScenario / (double)scenarioCount * (1.0 - UPDATE_PHASE_PROGRESS - BUILD_PHASE_PROGRESS) + UPDATE_PHASE_PROGRESS + BUILD_PHASE_PROGRESS;
            }];
        }];
        [failureRegex enumerateMatchesInString:output options:0 range:NSMakeRange(0, output.length) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
            if (failureCount < 0) {
                failureCount = 0;
            }
            failureCount += [[output substringWithRange:[result rangeAtIndex:1]] integerValue];
            *stop = YES;
        }];
        *stop = !self.running;
    } completionBlock:^(int exitCode) {
        // exitCode is probably always going to be 0 (success) coming from the simulator. Use the failure count as our status instead.
        NSLog(@"Simulator exited with code %d, failure count is %ld after %ld of %ld scenarios. Last output is %@", exitCode, failureCount, lastStartedScenario, scenarioCount, lastOutput);
        self.simulatorController = nil;
        
        // If failureCount is still -1 by the time we get here, it means the simulated app crashed. That's a failure.
        if (failureCount < 0) {
            failureCount = 1;
        }
        NSInteger newFailureCount = failureCount + initialFailureCount;
        if (self.running) {
            if (lastStartedScenario >= scenarioCount) {
                NSLog(@"finished: %ld/%ld", lastStartedScenario, scenarioCount);
                [self callCompletionBlockWithStatus:(int)newFailureCount];
            } else if (startsWithRetry && lastStartedScenario == initialSkip + 1) {
                NSLog(@"retry failed: %ld/%ld", lastStartedScenario, scenarioCount);
                [self runSimulatorWithAppPath:appPath initialSkip:lastStartedScenario failureCount:newFailureCount startsWithRetry:NO];
            } else {
                NSLog(@"retrying: %ld/%ld", lastStartedScenario, scenarioCount);
                [self runSimulatorWithAppPath:appPath initialSkip:lastStartedScenario - 1 failureCount:newFailureCount - 1 startsWithRetry:YES];
            }
        } else {
            [self callCompletionBlockWithStatus:-1];
        }
    }];
}

- (void)callCompletionBlockWithStatus:(int)exitStatus;
{
    [[NSOperationQueue mainQueue] addOperationWithBlock:^() {
        if (!self.completionBlock) {
            return;
        }

        @synchronized (self) {
            if (self.running) {
                self.status = exitStatus != 0 ? ZappBuildStatusFailed : ZappBuildStatusSucceeded;
            }
        }

        [ZappMessageController sendMessageIfNeededForBuild:self];
        NSLog(@"build complete, exit status %d", exitStatus);
        self.endTimestamp = [NSDate date];
        self.repository.latestBuildStatus = self.status;
        self.completionBlock();
        self.completionBlock = nil;
    }];
}

- (void)appendLogLines:(NSString *)newLogLinesString;
{
    NSArray *newLogLines = [newLogLinesString componentsSeparatedByString:@"\n"];
    void (^mainQueueBlock)(void) = ^{
        NSMutableArray *mutableLogLines = (NSMutableArray *)self.logLines;
        [self willChangeValueForKey:@"logLines"];
        if (![mutableLogLines isKindOfClass:[NSMutableArray class]]) {
            mutableLogLines = [NSMutableArray arrayWithArray:self.logLines];
            self.logLines = mutableLogLines;
        }
        for (NSString *line in newLogLines) {
            if (line.length > 0) {
                [mutableLogLines addObject:line];
            }
        }
        [self didChangeValueForKey:@"logLines"];
    };
    if ([[NSOperationQueue currentQueue] isEqual:[NSOperationQueue mainQueue]]) {
        mainQueueBlock();
    } else {
        [[NSOperationQueue mainQueue] addOperationWithBlock:mainQueueBlock];
    }
}

@end
