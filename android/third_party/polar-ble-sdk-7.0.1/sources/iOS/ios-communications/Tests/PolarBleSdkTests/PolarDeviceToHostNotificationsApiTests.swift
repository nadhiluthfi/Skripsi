//  Copyright © 2026 Polar. All rights reserved.

import XCTest
import RxSwift
import RxBlocking

@testable import PolarBleSdk

class PolarDeviceToHostNotificationsApiTests: XCTestCase {
    
    var mockClient: MockBlePsFtpClient!
    
    override func setUpWithError() throws {
        mockClient = MockBlePsFtpClient(gattServiceTransmitter: MockGattServiceTransmitterImpl())
    }
    
    override func tearDownWithError() throws {
        mockClient = nil
    }
    
    func testReceivesSyncRequiredNotification() throws {
        // Arrange
        let syncRequiredNotificationId = Protocol_PbPFtpDevToHostNotification.syncRequired.rawValue
        var syncRequiredNotificationParameter = Protocol_PbPFtpSyncRequiredParams()
        var syncTrigger = Protocol_PbPFtpSyncTrigger()
        syncTrigger.source = .timed
        syncRequiredNotificationParameter.syncTriggers = [syncTrigger]
        let syncRequiredNotificationParamsData = try syncRequiredNotificationParameter.serializedData()
        
        let keepAliveNotificationId = Protocol_PbPFtpDevToHostNotification.keepBackgroundAlive.rawValue
        
        let notifications = [
            (syncRequiredNotificationId, [syncRequiredNotificationParamsData], false),
            (keepAliveNotificationId, [Data()], false)
        ]
        
        mockClient.receiveNotificationCalls.append(contentsOf: notifications)
        
        // Act
        let results = try mockClient.observeDeviceToHostNotifications(identifier: UUID().uuidString)
            .toBlocking()
            .toArray()
        
        // Assert
        XCTAssertNotNil(results)
        XCTAssertEqual(results.count, 2)
        
        // Check first notification (SYNC_REQUIRED)
        XCTAssertEqual(results[0].notificationType, PolarDeviceToHostNotification.syncRequired)
        XCTAssertEqual(results[0].parameters, syncRequiredNotificationParamsData)
        XCTAssertNotNil(results[0].parsedParameters)
        XCTAssertTrue(results[0].parsedParameters is Protocol_PbPFtpSyncRequiredParams)
        let parsedParams = results[0].parsedParameters as! Protocol_PbPFtpSyncRequiredParams
        XCTAssertEqual(parsedParams, syncRequiredNotificationParameter)
        
        // Check second notification (KEEP_BACKGROUND_ALIVE)
        XCTAssertEqual(results[1].notificationType, PolarDeviceToHostNotification.keepBackgroundAlive)
        XCTAssertEqual(results[1].parameters.count, 0)
    }
    
    func testReceivesFilesystemModifiedNotification() throws {
        // Arrange
        let notificationId = Protocol_PbPFtpDevToHostNotification.filesystemModified.rawValue
        
        var fileSystemModifiedParams = Protocol_PbPFtpFilesystemModifiedParams()
        fileSystemModifiedParams.action = .created
        fileSystemModifiedParams.path = "/U/0/"
        let serializedData = try fileSystemModifiedParams.serializedData()
        let notificationParameters: [Data] = [serializedData]
        let mockNotifications = [
            (notificationId, notificationParameters, false)
        ]
        
        mockClient.receiveNotificationCalls.append(contentsOf: mockNotifications)
        
        // Act
        let result = try mockClient.observeDeviceToHostNotifications(identifier: UUID().uuidString)
            .toBlocking()
            .last()
        
        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.notificationType, PolarDeviceToHostNotification.filesystemModified)
        XCTAssertEqual(result!.parameters, serializedData)
        XCTAssertNotNil(result!.parsedParameters)
        XCTAssertTrue(result!.parsedParameters is Protocol_PbPFtpFilesystemModifiedParams)
        let parsedParams = result!.parsedParameters as! Protocol_PbPFtpFilesystemModifiedParams
        XCTAssertEqual(parsedParams, fileSystemModifiedParams)
    }
    
    func testReceivesInactivityAlertNotification() throws {
        // Arrange
        let notificationId = Protocol_PbPFtpDevToHostNotification.inactivityAlert.rawValue
        
        var inactivityAlertParams = Protocol_PbPFtpInactivityAlert()
        inactivityAlertParams.countdown = 5
        let serializedData = try inactivityAlertParams.serializedData()
        
        let notification = [(notificationId, [serializedData], false)]
        mockClient.receiveNotificationCalls.append(contentsOf: notification)
        
        // Act
        let result = try mockClient.observeDeviceToHostNotifications(identifier: UUID().uuidString)
            .toBlocking()
            .first()
        
        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.notificationType, PolarDeviceToHostNotification.inactivityAlert)
        XCTAssertEqual(result!.parameters, serializedData)
        XCTAssertNotNil(result!.parsedParameters)
        XCTAssertTrue(result!.parsedParameters is Protocol_PbPFtpInactivityAlert)
        let parsedParams = result!.parsedParameters as! Protocol_PbPFtpInactivityAlert
        XCTAssertEqual(parsedParams.countdown, 5)
    }
    
    func testReceivesTrainingSessionStatusNotification() throws {
        // Arrange
        let notificationId = Protocol_PbPFtpDevToHostNotification.trainingSessionStatus.rawValue
        
        var trainingSessionStatus = Protocol_PbPFtpTrainingSessionStatus()
        trainingSessionStatus.inprogress = true
        let serializedData = try trainingSessionStatus.serializedData()
        
        let notification = [(notificationId, [serializedData], false)]
        mockClient.receiveNotificationCalls.append(contentsOf: notification)
        
        // Act
        let result = try mockClient.observeDeviceToHostNotifications(identifier: UUID().uuidString)
            .toBlocking()
            .first()
        
        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.notificationType, PolarDeviceToHostNotification.trainingSessionStatus)
        XCTAssertEqual(result!.parameters, serializedData)
        XCTAssertNotNil(result!.parsedParameters)
        XCTAssertTrue(result!.parsedParameters is Protocol_PbPFtpTrainingSessionStatus)
        let parsedParams = result!.parsedParameters as! Protocol_PbPFtpTrainingSessionStatus
        XCTAssertTrue(parsedParams.inprogress)
    }
    
    func testReceivesAutosyncStatusNotification() throws {
        // Arrange
        let notificationId = Protocol_PbPFtpDevToHostNotification.autosyncStatus.rawValue
        
        var autoSyncStatus = Protocol_PbPFtpAutoSyncStatusParams()
        autoSyncStatus.succeeded = true
        autoSyncStatus.description_p = "Sync completed successfully"
        let serializedData = try autoSyncStatus.serializedData()
        
        let notification = [(notificationId, [serializedData], false)]
        mockClient.receiveNotificationCalls.append(contentsOf: notification)
        
        // Act
        let result = try mockClient.observeDeviceToHostNotifications(identifier: UUID().uuidString)
            .toBlocking()
            .first()
        
        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.notificationType, PolarDeviceToHostNotification.autosyncStatus)
        XCTAssertEqual(result!.parameters, serializedData)
        XCTAssertNotNil(result!.parsedParameters)
        XCTAssertTrue(result!.parsedParameters is Protocol_PbPFtpAutoSyncStatusParams)
        let parsedParams = result!.parsedParameters as! Protocol_PbPFtpAutoSyncStatusParams
        XCTAssertTrue(parsedParams.succeeded)
        XCTAssertEqual(parsedParams.description_p, "Sync completed successfully")
    }
    
    func testReceivesNotificationWithoutParameters() throws {
        // Arrange
        let notificationId = Protocol_PbPFtpDevToHostNotification.stopGpsMeasurement.rawValue
        
        let notification = [(notificationId, [Data()], false)]
        mockClient.receiveNotificationCalls.append(contentsOf: notification)
        
        // Act
        let result = try mockClient.observeDeviceToHostNotifications(identifier: UUID().uuidString)
            .toBlocking()
            .first()
        
        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.notificationType, PolarDeviceToHostNotification.stopGpsMeasurement)
        XCTAssertEqual(result!.parameters.count, 0)
        XCTAssertNil(result!.parsedParameters)
    }
    
    func testFiltersUnknownNotificationTypes() throws {
        // Arrange
        let unknownNotificationId: Int = 999
        let validNotificationId = Protocol_PbPFtpDevToHostNotification.idling.rawValue
        
        let notifications = [
            (unknownNotificationId, [Data()], false),
            (validNotificationId, [Data()], false)
        ]
        mockClient.receiveNotificationCalls.append(contentsOf: notifications)
        
        // Act
        let results = try mockClient.observeDeviceToHostNotifications(identifier: UUID().uuidString)
            .toBlocking()
            .toArray()
        
        // Assert
        // Unknown notification should be filtered out
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].notificationType, PolarDeviceToHostNotification.idling)
    }
    
    func testHandlesInvalidProtobufDataGracefully() throws {
        // Arrange
        let notificationId = Protocol_PbPFtpDevToHostNotification.syncRequired.rawValue
        let invalidData = "invalid protobuf data".data(using: .utf8)!
        
        let notification = [(notificationId, [invalidData], false)]
        mockClient.receiveNotificationCalls.append(contentsOf: notification)
        
        // Act
        let result = try mockClient.observeDeviceToHostNotifications(identifier: UUID().uuidString)
            .toBlocking()
            .first()
        
        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.notificationType, PolarDeviceToHostNotification.syncRequired)
        XCTAssertEqual(result!.parameters, invalidData)
        // parsedParameters should be nil for invalid data
        XCTAssertNil(result!.parsedParameters)
    }
    
    func testReceivesMediaControlRequestNotification() throws {
        // Arrange
        let notificationId = Protocol_PbPFtpDevToHostNotification.mediaControlRequestDh.rawValue
        
        var mediaControlRequest = Protocol_PbPftpDHMediaControlRequest()
        mediaControlRequest.request = .getMediaData
        let serializedData = try mediaControlRequest.serializedData()
        
        let notification = [(notificationId, [serializedData], false)]
        mockClient.receiveNotificationCalls.append(contentsOf: notification)
        
        // Act
        let result = try mockClient.observeDeviceToHostNotifications(identifier: UUID().uuidString)
            .toBlocking()
            .first()
        
        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.notificationType, PolarDeviceToHostNotification.mediaControlRequestDh)
        XCTAssertEqual(result!.parameters, serializedData)
        XCTAssertNotNil(result!.parsedParameters)
        XCTAssertTrue(result!.parsedParameters is Protocol_PbPftpDHMediaControlRequest)
        let parsedParams = result!.parsedParameters as! Protocol_PbPftpDHMediaControlRequest
        XCTAssertEqual(parsedParams.request, .getMediaData)
    }
    
    func testReceivesMediaControlCommandNotification() throws {
        // Arrange
        let notificationId = Protocol_PbPFtpDevToHostNotification.mediaControlCommandDh.rawValue
        
        var mediaControlCommand = Protocol_PbPftpDHMediaControlCommand()
        mediaControlCommand.command = .play
        let serializedData = try mediaControlCommand.serializedData()
        
        let notification = [(notificationId, [serializedData], false)]
        mockClient.receiveNotificationCalls.append(contentsOf: notification)
        
        // Act
        let result = try mockClient.observeDeviceToHostNotifications(identifier: UUID().uuidString)
            .toBlocking()
            .first()
        
        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.notificationType, PolarDeviceToHostNotification.mediaControlCommandDh)
        XCTAssertEqual(result!.parameters, serializedData)
        XCTAssertNotNil(result!.parsedParameters)
        XCTAssertTrue(result!.parsedParameters is Protocol_PbPftpDHMediaControlCommand)
        let parsedParams = result!.parsedParameters as! Protocol_PbPftpDHMediaControlCommand
        XCTAssertEqual(parsedParams.command, .play)
    }
    
    func testReceivesStartGpsMeasurementNotification() throws {
        // Arrange
        let notificationId = Protocol_PbPFtpDevToHostNotification.startGpsMeasurement.rawValue
        
        var startGpsMeasurement = Protocol_PbPftpStartGPSMeasurement()
        startGpsMeasurement.minimumInterval = 1000
        startGpsMeasurement.accuracy = 2
        startGpsMeasurement.latitude = 60.1695
        startGpsMeasurement.longitude = 24.9354
        let serializedData = try startGpsMeasurement.serializedData()
        
        let notification = [(notificationId, [serializedData], false)]
        mockClient.receiveNotificationCalls.append(contentsOf: notification)
        
        // Act
        let result = try mockClient.observeDeviceToHostNotifications(identifier: UUID().uuidString)
            .toBlocking()
            .first()
        
        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.notificationType, PolarDeviceToHostNotification.startGpsMeasurement)
        XCTAssertEqual(result!.parameters, serializedData)
        XCTAssertNotNil(result!.parsedParameters)
        XCTAssertTrue(result!.parsedParameters is Protocol_PbPftpStartGPSMeasurement)
        let parsedParams = result!.parsedParameters as! Protocol_PbPftpStartGPSMeasurement
        XCTAssertEqual(parsedParams.minimumInterval, 1000)
        XCTAssertEqual(parsedParams.accuracy, 2)
        XCTAssertEqual(parsedParams.latitude, 60.1695, accuracy: 0.0001)
        XCTAssertEqual(parsedParams.longitude, 24.9354, accuracy: 0.0001)
    }
}
