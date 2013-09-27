#import "MeteorClient.h"
#import "ObjectiveDDP.h"

using namespace Cedar::Matchers;
using namespace Cedar::Doubles;
using namespace Arguments;

SPEC_BEGIN(MeteorClientSpec)

describe(@"MeteorClient", ^{
    __block MeteorClient *meteorClient;
    __block ObjectiveDDP *ddp;

    beforeEach(^{
        ddp = nice_fake_for([ObjectiveDDP class]);
        meteorClient = [[[MeteorClient alloc] init] autorelease];
        ddp.delegate = meteorClient;
        meteorClient.ddp = ddp;
        meteorClient.authDelegate = nice_fake_for(@protocol(DDPAuthDelegate));
        spy_on(ddp);
    });

    it(@"is correctly initialized", ^{
        meteorClient.websocketReady should_not be_truthy;
        meteorClient.collections should_not be_nil;
        meteorClient.subscriptions should_not be_nil;
        meteorClient.websocketReady should_not be_truthy;
    });

    describe(@"#addSubscription:", ^{
        context(@"when websocket is ready", ^{
            beforeEach(^{
                meteorClient.websocketReady = YES;
                [meteorClient addSubscription:@"a fancy subscription"];
            });

            it(@"should call ddp subscribe method", ^{
                ddp should have_received("subscribeWith:name:parameters:").with(anything)
                .and_with(@"a fancy subscription")
                .and_with(nil);
            });
        });

        context(@"when websocket is not ready", ^{
            beforeEach(^{
                meteorClient.websocketReady = NO;
                [meteorClient addSubscription:@"a fancy subscription"];
            });

            it(@"should not call ddp subscribe method", ^{
                ddp should_not have_received("subscribeWith:name:parameters:");
            });
        });
    });

    describe(@"#removeSubscription:", ^{
        context(@"when the websocket is ready", ^{
            beforeEach(^{
                meteorClient.websocketReady = YES;
                [meteorClient.subscriptions setObject:@"id1"
                                               forKey:@"fancySubscriptionName"];
                [meteorClient.subscriptions count] should equal(1);
                [meteorClient removeSubscription:@"fancySubscriptionName"];
            });

            it(@"removes subscription correctly", ^{
                ddp should have_received(@selector(unsubscribeWith:));
                [meteorClient.subscriptions count] should equal(0);
            });
        });

        context(@"when the websocket is not ready", ^{
            beforeEach(^{
                meteorClient.websocketReady = NO;
                [meteorClient.subscriptions setObject:@"id1"
                                               forKey:@"fancySubscriptionName"];
                [meteorClient.subscriptions count] should equal(1);
                [meteorClient removeSubscription:@"fancySubscriptionName"];
            });

            it(@"does not remove subscription", ^{
                ddp should_not have_received(@selector(unsubscribeWith:));
                [meteorClient.subscriptions count] should equal(1);
            });
        });
    });

    describe(@"#sendMethodWithName:parameters:notifyOnResponse", ^{
        __block NSString *methodId;

        context(@"when websocket is ready", ^{
            beforeEach(^{
                meteorClient.websocketReady = YES;
                [meteorClient.methodIds count] should equal(0);
                methodId = [meteorClient sendWithMethodName:@"awesomeMethod" parameters:@[] notifyOnResponse:YES];
            });

            it(@"stores a method id", ^{
                [meteorClient.methodIds count] should equal(1);
                [meteorClient.methodIds allObjects][0] should equal(methodId);
            });

            it(@"sends method command correctly", ^{
                ddp should have_received(@selector(methodWithId:method:parameters:))
                .with(methodId)
                .and_with(@"awesomeMethod")
                .and_with(@[]);
            });
        });

        context(@"when websocket is not ready", ^{
            beforeEach(^{
                meteorClient.websocketReady = NO;
                [meteorClient.methodIds count] should equal(0);
                methodId = [meteorClient sendWithMethodName:@"awesomeMethod" parameters:@[] notifyOnResponse:YES];
            });

            it(@"does not store a method id", ^{
                [meteorClient.methodIds count] should equal(0);
            });

            it(@"does not send method command", ^{
                ddp should_not have_received(@selector(methodWithId:method:parameters:));
            });
        });
    });

    describe(@"#logonWithUserName:password:", ^{
        context(@"when websocket is ready", ^{
            beforeEach(^{
                meteorClient.websocketReady = YES;
                [meteorClient logonWithUsername:@"JesseJames"
                                       password:@"shot3mUp!"];
            });

            it(@"sends logon message correctly", ^{
                // XXX: add custom matcher that can query the params
                //      to see what user/pass was sent
                ddp should have_received(@selector(methodWithId:method:parameters:))
                    .with(anything)
                    .and_with(@"beginPasswordExchange")
                    .and_with(anything);
            });
        });

        context(@"when websocket is ready", ^{
            beforeEach(^{
                meteorClient.websocketReady = NO;
                [meteorClient logonWithUsername:@"JesseJames"
                                       password:@"shot3mUp!"];
            });

            it(@"sends logon message correctly", ^{
                ddp should_not have_received(@selector(methodWithId:method:parameters:));
            });
        });
    });

    describe(@"#didOpen", ^{
        beforeEach(^{
            meteorClient.collections = [NSMutableDictionary dictionaryWithDictionary:@{@"col1": [NSArray new]}];
            [meteorClient.collections count] should equal(1);
            [meteorClient didOpen];
        });

        it(@"sets the web socket state to ready", ^{
            meteorClient.websocketReady should be_truthy;
            [meteorClient.collections count] should equal(0);
            ddp should have_received(@selector(connectWithSession:version:support:));
        });
    });

    describe(@"#didReceiveConnectionClose", ^{
        beforeEach(^{
            [meteorClient didReceiveConnectionClose];
        });

        // TODO: fix when reconnect logic is worked out
        xit(@"resets collections and reconnects web socket", ^{
            meteorClient.websocketReady should_not be_truthy;
            ddp should have_received(@selector(connectWebSocket));
        });
    });

    describe(@"#didReceiveMessage", ^{
        beforeEach(^{
            spy_on([NSNotificationCenter defaultCenter]);
        });

        context(@"when called with a custom method response message", ^{
            __block NSString *key;
            __block NSDictionary *methodResponseMessage;

            beforeEach(^{
                key = @"key1";
                methodResponseMessage = @{
                    @"msg": @"result",
                    @"result": @"awesomesauce",
                    @"id": key
                };
                [meteorClient.methodIds addObject:key];
                [meteorClient didReceiveMessage:methodResponseMessage];
            });

            it(@"removes the message id", ^{
                [meteorClient.methodIds containsObject:key] should_not be_truthy;
            });

            it(@"sends a notification", ^{
                NSString *notificationName = [NSString stringWithFormat:@"response_%@", key];
                [NSNotificationCenter defaultCenter] should have_received(@selector(postNotificationName:object:userInfo:))
                    .with(notificationName)
                    .and_with(meteorClient)
                    .and_with(methodResponseMessage[@"result"]);
            });
        });

        context(@"when called with an authentication error message", ^{
            beforeEach(^{
                NSDictionary *authErrorMessage = @{
                    @"msg": @"result",
                    @"error": @{@"error": @403, @"reason": @"are you kidding me?"}
                };
                [meteorClient didReceiveMessage:authErrorMessage];
            });

            it(@"processes the message correctly", ^{
                meteorClient.authDelegate should have_received(@selector(authenticationFailed:)).with(@"are you kidding me?");
            });
        });
        
        context(@"when subscription is ready", ^{
            beforeEach(^{

                [meteorClient.subscriptions setObject:@"subid" forKey:@"subscriptionName"];
                
                NSDictionary *readyMessage = @{
                                               @"msg":@"ready",
                                               @"subs":@[@"subid"]
                                               };
                
                [meteorClient didReceiveMessage:readyMessage];
            });
            
            it(@"processes the message correctly", ^{
                SEL postSel = @selector(postNotificationName:object:);
                [NSNotificationCenter defaultCenter] should have_received(postSel)
                    .with(@"subscriptionName_ready")
                    .and_with(meteorClient);
            });
        });

        context(@"when called with an 'added' message", ^{
            beforeEach(^{
                NSDictionary *addedMessage = @{
                    @"msg": @"added",
                    @"id": @"id1",
                    @"collection": @"phrases",
                    @"fields": @{@"text": @"this is ridiculous"}
                };

                [meteorClient didReceiveMessage:addedMessage];
            });

            it(@"processes the message correctly", ^{
                [meteorClient.collections[@"phrases"] count] should equal(1);
                NSDictionary *phrase = meteorClient.collections[@"phrases"][0];
                phrase[@"text"] should equal(@"this is ridiculous");
                SEL postSel = @selector(postNotificationName:object:userInfo:);
                [NSNotificationCenter defaultCenter] should have_received(postSel).with(@"added")
                                                                                  .and_with(meteorClient)
                                                                                  .and_with(phrase);
                [NSNotificationCenter defaultCenter] should have_received(postSel).with(@"phrases_added")
                                                                                  .and_with(meteorClient)
                                                                                  .and_with(phrase);
            });

            context(@"when called with a changed message", ^{
                beforeEach(^{
                    NSDictionary *changedMessage = @{
                        @"msg": @"changed",
                        @"id": @"id1",
                        @"collection": @"phrases",
                        @"fields": @{@"text": @"this is really ridiculous"}
                    };

                    [meteorClient didReceiveMessage:changedMessage];
                });

                it(@"processes the message correctly", ^{
                    [meteorClient.collections[@"phrases"] count] should equal(1);
                    NSDictionary *phrase = meteorClient.collections[@"phrases"][0];
                    phrase[@"text"] should equal(@"this is really ridiculous");
                    SEL postSel = @selector(postNotificationName:object:userInfo:);
                    [NSNotificationCenter defaultCenter] should have_received(postSel).with(@"changed")
                                                                                       .and_with(meteorClient)
                                                                                       .and_with(phrase);
                    [NSNotificationCenter defaultCenter] should have_received(postSel).with(@"phrases_changed")
                                                                                       .and_with(meteorClient)
                                                                                       .and_with(phrase);
                });
            });

            context(@"when called with a removed message", ^{
                beforeEach(^{
                    NSDictionary *removedMessage = @{
                        @"msg": @"removed",
                        @"id": @"id1",
                        @"collection": @"phrases",
                    };

                    [meteorClient didReceiveMessage:removedMessage];
                });

                it(@"processes the message correctly", ^{
                    [meteorClient.collections[@"phrases"] count] should equal(0);
                    SEL postSel = @selector(postNotificationName:object:);
                    [NSNotificationCenter defaultCenter] should have_received(postSel).with(@"removed")
                                                                                      .and_with(meteorClient);
                    [NSNotificationCenter defaultCenter] should have_received(postSel).with(@"phrases_removed")
                                                                                      .and_with(meteorClient);
                });
            });
        });
    });
});

describe(@"MeteorClient SRP Auth", ^{
    __block MeteorClient *meteorClient;

    beforeEach(^{
        meteorClient = [[MeteorClient alloc] init];
    });

    describe(@"-generateAuthVerificationKeyWithUsername:password", ^{
        __block NSString *authKey;

        beforeEach(^{
            authKey = [meteorClient generateAuthVerificationKeyWithUsername:@"joeuser" password:@"secretsauce"];
        });

        it(@"computes the key correctly", ^{
            authKey should_not be_nil;
        });
    });
});

SPEC_END
