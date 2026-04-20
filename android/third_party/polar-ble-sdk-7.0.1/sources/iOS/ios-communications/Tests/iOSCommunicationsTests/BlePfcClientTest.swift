import XCTest
@testable import iOSCommunications
import RxSwift
import RxBlocking

final class BlePfcClientTest: XCTestCase {

    var mockGattServiceTransmitterImpl: MockGattServiceTransmitterImpl!
    var blePfcClient: BlePfcClient!
    var disposeBag: DisposeBag!

    override func setUpWithError() throws {
        mockGattServiceTransmitterImpl = MockGattServiceTransmitterImpl()
        disposeBag = DisposeBag()
        blePfcClient = BlePfcClient(gattServiceTransmitter: mockGattServiceTransmitterImpl)
    }

    override func tearDownWithError() throws {
        mockGattServiceTransmitterImpl = nil
        blePfcClient = nil
        disposeBag = nil
    }

    func testSecurityModeSupportedFeatureParsing() throws {
        // Arrange
        // byte1 bit1 => security mode supported
        let featureData = Data([
            0x00,
            0x02
        ])

        // Act
        blePfcClient.processServiceData(
            blePfcClient.PFC_FEATURE,
            data: featureData,
            err: 0
        )

        let feature = try blePfcClient
            .readFeature(false)
            .toBlocking()
            .single()

        // Assert
        XCTAssertTrue(feature.securityModeSupported)
    }

    func testProcessConfigureSensorInitiatedSecurityModeResponseIsQueued() throws {
        // Arrange
        let response = Data([
            0xF0, // response code
            0x0E, // CONFIGURE_SENSOR_INITIATED_SECURITY_MODE
            0x00  // SUCCESS
        ])

        // Act
        blePfcClient.processServiceData(
            BlePfcClient.PFC_CP,
            data: response,
            err: 0
        )

        // Assert
        let queued = try blePfcClient.pfcInputQueue.poll(1)
        XCTAssertEqual(response, queued.first?.0)
        XCTAssertEqual(0, queued.first?.1)
    }

    func testSendConfigureSensorInitiatedSecurityModeCommand() throws {
        // Arrange
        mockGattServiceTransmitterImpl.mockConnectionStatus = true

        try blePfcClient
            .clientReady(false)
            .toBlocking()
            .first()

        let response = Data([
            0xF0,
            0x0E,
            0x00
        ])

        blePfcClient.processServiceData(
            BlePfcClient.PFC_CP,
            data: response,
            err: 0
        )

        // Act
        let result = try blePfcClient
            .sendControlPointCommand(
                .pfcConfigureSensorInitiatedSecurityMode,
                value: 0x01
            )
            .toBlocking()
            .single()

        // Assert
        XCTAssertEqual(result.opCode, 0x0E)
        XCTAssertEqual(result.status, .success)
    }

    func testSendRequestSecurityModeCommand() throws {
        // Arrange
        mockGattServiceTransmitterImpl.mockConnectionStatus = true

        try blePfcClient
            .clientReady(false)
            .toBlocking()
            .first()

        let response = Data([
            0xF0,
            0x0C, // REQUEST_SECURITY_MODE
            0x00,
            0x01  // secure connection
        ])

        blePfcClient.processServiceData(
            BlePfcClient.PFC_CP,
            data: response,
            err: 0
        )

        // Act
        let result = try blePfcClient
            .sendControlPointCommand(.pfcRequestSecurityMode, value: [])
            .toBlocking()
            .single()

        // Assert
        XCTAssertEqual(result.opCode, 0x0C)
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.payload.first, 0x01)
    }

    func testSendRequestSensorInitiatedSecurityModeCommand() throws {
        // Arrange
        mockGattServiceTransmitterImpl.mockConnectionStatus = true

        try blePfcClient
            .clientReady(false)
            .toBlocking()
            .first()

        let response = Data([
            0xF0,
            0x0F,
            0x00,
            0x01
        ])

        blePfcClient.processServiceData(
            BlePfcClient.PFC_CP,
            data: response,
            err: 0
        )

        // Act
        let result = try blePfcClient
            .sendControlPointCommand(.pfcRequestSensorInitiatedSecurityMode, value: [])
            .toBlocking()
            .single()

        // Assert
        XCTAssertEqual(result.opCode, 0x0F)
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.payload.first, 0x01)
    }
}
