#import "MeteorClient.h"
#import "BSONIdGenerator.h"
#import "srp/srp.h"

@interface MeteorClient ()

@property (nonatomic, copy) NSString *password;
@property (nonatomic, retain) NSTimer *timer;

@end

@implementation MeteorClient

- (id)init {
    self = [super init];
    if (self) {
        self.collections = [NSMutableDictionary dictionary];
        self.subscriptions = [NSMutableDictionary dictionary];
        self.subscriptionsParameters = [NSMutableDictionary dictionary];
        self.methodIds = [NSMutableSet set];
        // TODO: subscription version should be set here
    }
    return self;
}

#pragma mark MeteorClient public API

- (void)resetCollections {
    [self.collections removeAllObjects];
}

-(NSString *)sendWithMethodName:(NSString *)methodName parameters:(NSArray *)parameters notifyOnResponse:(BOOL)notify {
    NSString *methodId = [[BSONIdGenerator generate] substringToIndex:15];
    
    if(notify == YES) {
        [self.methodIds addObject:methodId];
    }

    [self.ddp methodWithId:methodId
                    method:methodName
                parameters:parameters];
    
    return methodId;
}

- (void)sendWithMethodName:(NSString *)methodName parameters:(NSArray *)parameters {
    [self sendWithMethodName:methodName parameters:parameters notifyOnResponse:NO];
}

- (void)addSubscription:(NSString *)subscriptionName {
    NSString *uid = [[BSONIdGenerator generate] substringToIndex:15];

    [self.subscriptions setObject:uid
                           forKey:subscriptionName];
    [self.ddp subscribeWith:uid name:subscriptionName parameters:nil];
}

- (void)addSubscription:(NSString *)subscriptionName withParameters:(NSArray *)parameters {
    NSString *uid = [[BSONIdGenerator generate] substringToIndex:15];
    
    [self.subscriptions setObject:uid
                           forKey:subscriptionName];
    [self.subscriptionsParameters setObject:parameters forKey:subscriptionName];
    
    [self.ddp subscribeWith:uid name:subscriptionName parameters:parameters];
}

-(void)removeSubscription:(NSString *)subscriptionName {
    NSString *uid = [self.subscriptions objectForKey:subscriptionName];
    
    if (uid) {
        [self.ddp unsubscribeWith:uid];
        [self.subscriptions removeObjectForKey:subscriptionName];
    }
}

- (void)logonWithUsername:(NSString *)username password:(NSString *)password {
    NSArray *params = @[@{@"A": [self generateAuthVerificationKeyWithUsername:username password:password],
                          @"user": @{@"email":username}}];

    [self sendWithMethodName:@"beginPasswordExchange"
                  parameters:params];
}

#pragma mark <ObjectiveDDPDelegate>

- (void)didOpen {
    [self.timer invalidate];
    self.timer = nil;
    self.websocketReady = YES;
    [self resetCollections];
    // TODO: pre1 should be a setting
    [self.ddp connectWithSession:nil version:@"pre1" support:nil];
}

- (void)didReceiveMessage:(NSDictionary *)message {
    NSString *msg = [message objectForKey:@"msg"];
    NSString *messageId = message[@"id"];

    if ([self.methodIds containsObject:messageId]) {
        if(msg && [msg isEqualToString:@"result"]) {
            NSDictionary *response = message[@"result"];
            NSString *notificationName = [NSString stringWithFormat:@"response_%@", message[@"id"]];
            [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:self userInfo:response];
            [self.methodIds removeObject:messageId];
        }
    } else if (msg && [msg isEqualToString:@"result"]
            && message[@"result"]
            && message[@"result"][@"B"]
            && message[@"result"][@"identity"]
            && message[@"result"][@"salt"]) {
        NSDictionary *response = message[@"result"];
        [self didReceiveLoginChallengeWithResponse:response];
    } else if(msg && [msg isEqualToString:@"result"]
              && message[@"error"]
              && [message[@"error"][@"error"]integerValue] == 403) {
        [self.authDelegate authenticationFailed:message[@"error"][@"reason"]];
    } else if (msg && [msg isEqualToString:@"result"]
            && message[@"result"]
            && message[@"result"][@"id"]
            && message[@"result"][@"HAMK"]
            && message[@"result"][@"token"]) {
        NSDictionary *response = message[@"result"];
        [self didReceiveHAMKVerificationWithResponse:response];
    } else if (msg && [msg isEqualToString:@"added"]
            && message[@"collection"]) {
        NSDictionary *object = [self _parseObjectAndAddToCollection:message];
        NSString *notificationName = [NSString stringWithFormat:@"%@_added", message[@"collection"]];
        [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:self userInfo:object];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"added" object:self userInfo:object];
    } else if (msg && [msg isEqualToString:@"removed"]
               && message[@"collection"]) {
        [self _parseRemoved:message];
        NSString *notificationName = [NSString stringWithFormat:@"%@_removed", message[@"collection"]];
        [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:self];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"removed" object:self];
    } else if (msg && [msg isEqualToString:@"changed"]
               && message[@"collection"]) {
        NSDictionary *object = [self _parseObjectAndUpdateCollection:message];
        NSString *notificationName = [NSString stringWithFormat:@"%@_changed", message[@"collection"]];
        [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:self userInfo:object];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"changed" object:self userInfo:object];
    } else if (msg && [msg isEqualToString:@"connected"]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"connected" object:nil];
        if (self.sessionToken) {
            NSArray *params = @[@{@"resume": self.sessionToken}];
            [self sendWithMethodName:@"login"
                          parameters:params];
        }
        [self makeMeteorDataSubscriptions];
    } else if (msg && [msg isEqualToString:@"ready"]) {
        NSArray *subs = message[@"subs"];
        for(NSString *readySubscription in subs) {
            for(NSString *subscriptionName in self.subscriptions) {
                NSString *curSubId = self.subscriptions[subscriptionName];
                if([curSubId isEqualToString:readySubscription]) {
                    NSString *notificationName = [NSString stringWithFormat:@"%@_ready", subscriptionName];
                    [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:self];
                    break;
                }
            }
        }
    }
}

- (void)didReceiveConnectionError:(NSError *)error {
    NSLog(@"================> didReceiveConnectionError: %@", error);
}

- (void)reconnect {
    if (self.ddp.webSocket.readyState == SR_OPEN) {
        [self.timer invalidate];
        self.timer = nil;
        return;
    }

    [self.ddp connectWebSocket];
}

- (void)didReceiveConnectionClose {
    self.websocketReady = NO;
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:5
                                                  target:self
                                                selector:@selector(reconnect)
                                                userInfo:nil
                                                 repeats:YES];
}

#pragma mark Meteor Data Managment

- (void)makeMeteorDataSubscriptions {
    for (NSString *key in [self.subscriptions allKeys]) {
        NSString *uid = [[BSONIdGenerator generate] substringToIndex:15];
        [self.subscriptions setObject:uid forKey:key];  
        NSArray *params = self.subscriptionsParameters[key];
        [self.ddp subscribeWith:uid name:key parameters:params];
    }
}

- (NSDictionary *)_parseObjectAndUpdateCollection:(NSDictionary *)message {
    NSPredicate *pred = [NSPredicate predicateWithFormat:@"(_id like %@)", message[@"id"]];
    NSMutableArray *collection = self.collections[message[@"collection"]];
    NSArray *filteredArray = [collection filteredArrayUsingPredicate:pred];
    NSMutableDictionary *object = filteredArray[0];
    for (id key in message[@"fields"]) {
        object[key] = message[@"fields"][key];
    }
    return object;
}

- (NSDictionary *)_parseObjectAndAddToCollection:(NSDictionary *)message {
    NSMutableDictionary *object = [NSMutableDictionary dictionaryWithDictionary:@{@"_id": message[@"id"]}];

    for (id key in message[@"fields"]) {
        object[key] = message[@"fields"][key];
    }

    if (!self.collections[message[@"collection"]]) {
        self.collections[message[@"collection"]] = [NSMutableArray array];
    }

    NSMutableArray *collection = self.collections[message[@"collection"]];

    [collection addObject:object];

    return object;
}

- (void)_parseRemoved:(NSDictionary *)message {
    NSString *removedId = [message objectForKey:@"id"];
    int indexOfRemovedObject = 0;

    NSMutableArray *collection = self.collections[message[@"collection"]];

    for (NSDictionary *object in collection) {
        if ([object[@"_id"] isEqualToString:removedId]) {
            break;
        }
        indexOfRemovedObject++;
    }

    [collection removeObjectAtIndex:indexOfRemovedObject];
}

# pragma mark Meteor SRP Wrapper

SRP_HashAlgorithm alg     = SRP_SHA256;
SRP_NGType        ng_type = SRP_NG_1024;
struct SRPUser     * usr;

- (NSString *)generateAuthVerificationKeyWithUsername:(NSString *)username password:(NSString *)password {
    //TODO: don't really need to keep bytes_A and len_A here, could remove them and push into srp lib
    const unsigned char * bytes_A = 0;
    int len_A   = 0;
    const char * Astr = 0;
    const char * auth_username = 0;
    const char * username_str = [username cStringUsingEncoding:NSASCIIStringEncoding];
    const char * password_str = [password cStringUsingEncoding:NSASCIIStringEncoding];

    self.password = password;

    /* Begin authentication process */
    usr = srp_user_new(alg,
            ng_type,
            username_str,
            password_str,
            strlen(password_str),
            NULL,
            NULL);

    srp_user_start_authentication(usr,
            &auth_username,
            &bytes_A,
            &len_A,
            &Astr);

    return [NSString stringWithCString:Astr encoding:NSASCIIStringEncoding];
}

- (void)didReceiveLoginChallengeWithResponse:(NSDictionary *)response {
    NSString *B_string = response[@"B"];
    const char *B = [B_string cStringUsingEncoding:NSASCIIStringEncoding];
    NSString *salt_string = response[@"salt"];
    const char *salt = [salt_string cStringUsingEncoding:NSASCIIStringEncoding];
    NSString *identity_string = response[@"identity"];
    const char *identity = [identity_string cStringUsingEncoding:NSASCIIStringEncoding];
    const char * password_str = [self.password cStringUsingEncoding:NSASCIIStringEncoding];
    const char * Mstr;

    srp_user_process_meteor_challenge(usr, password_str, salt, identity, B, &Mstr);
    NSString *M_final = [NSString stringWithCString:Mstr encoding:NSASCIIStringEncoding];
    NSArray *params = @[@{@"srp":@{@"M":M_final}}];

    [self sendWithMethodName:@"login"
                  parameters:params];
}

- (void)didReceiveHAMKVerificationWithResponse:(NSDictionary *)response {
    srp_user_verify_meteor_session(usr, [response[@"HAMK"] cStringUsingEncoding:NSASCIIStringEncoding]);

    if (srp_user_is_authenticated) {
        self.sessionToken = response[@"token"];
        self.userId = response[@"id"];
        [self.authDelegate authenticationWasSuccessful];
    }
}

@end
