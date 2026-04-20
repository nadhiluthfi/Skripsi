//  Copyright © 2026 Polar. All rights reserved.

import Foundation
import XCTest
import RxSwift
import CoreBluetooth
@testable import PolarBleSdk

class PolarBleApiImplWithMockSession: PolarBleApiImpl {
    required init(_ queue: DispatchQueue, features: Set<PolarBleSdkFeature>) {
        fatalError("init(_:features:) has not been implemented")
    }
    
    init(mockDeviceSession: MockBleDeviceSession) {
        self.mockDeviceSession = mockDeviceSession
        super.init(DispatchQueue(label: "test"), features: [])
    }
    let mockDeviceSession: MockBleDeviceSession
    
    override var serviceClientUtils: PolarServiceClientUtils {
        return MockPolarServiceClientUtils(listener: MockCBDeviceListenerImpl(), session: mockDeviceSession)
    }
}

class MockCBDeviceListenerImpl: CBDeviceListenerImpl {
    
    var listener: CBDeviceListenerImpl
    var clientList: [(_ gattServiceTransmitter: BleAttributeTransportProtocol) -> BleGattClientBase] = []
    
    init() {
        clientList.append(BlePmdClient.init)
        listener = CBDeviceListenerImpl(DispatchQueue(label: "test"), clients: clientList, identifier: 0)
        super.init(DispatchQueue(label: "test"), clients: clientList, identifier: 0)
    }
}

class MockPolarServiceClientUtils: PolarServiceClientUtils {
   
    var mockListener: MockCBDeviceListenerImpl!
    var mockSession: MockBleDeviceSession
    init(listener: MockCBDeviceListenerImpl, session: MockBleDeviceSession) {
        self.mockSession = session
        self.mockListener = listener
        super.init(listener: listener)
    }
    
    required init(listener: CBDeviceListenerImpl) {
        fatalError("init(listener:) has not been implemented")
    }
    override func sessionFtpClientReady(_ identifier: String) throws -> BleDeviceSession {
        return mockSession
    }
}

class MockAdvertisementContent: BleAdvertisementContent {
    override var polarDeviceType: String {
        return "360"
    }
}

class MockBleDeviceSession: BleDeviceSession {
    init(mockFtpClient: MockBlePsFtpClient) {
        self.mockFtpClient = mockFtpClient
        super.init(UUID(), advertisementContent: MockAdvertisementContent())
    }
    let mockFtpClient: MockBlePsFtpClient
    public override func fetchGattClient(_ serviceUuid: CBUUID) -> BleGattClientBase? {
        return mockFtpClient
    }
}

class MockGattServiceTransmitterImpl: BleAttributeTransportProtocol {
    var mockConnectionStatus: Bool = true
    var setCharacteristicsNotifyCache: [(characteristicUuid: CBUUID, notify: Bool)] = []
    
    func isConnected() -> Bool {
        return mockConnectionStatus
    }
    
    func transmitMessage(_ parent: BleGattClientBase, serviceUuid: CBUUID , characteristicUuid: CBUUID , packet: Data, withResponse: Bool) throws {
        // Do nothing
    }
    
    func characteristicWith(uuid: CBUUID) throws -> CBCharacteristic? {
        return nil
    }
    
    func characteristicNameWith(uuid: CBUUID) -> String? {
        return nil
    }
    
    func readValue(_ parent: BleGattClientBase, serviceUuid: CBUUID , characteristicUuid: CBUUID ) throws {
        // Do nothing
    }
    
    func setCharacteristicNotify(_ parent: BleGattClientBase, serviceUuid: CBUUID, characteristicUuid: CBUUID, notify: Bool) throws {
        setCharacteristicsNotifyCache.append((characteristicUuid, notify))
        parent.notifyDescriptorWritten(characteristicUuid, enabled: notify, err: 0)
    }
    
    func attributeOperationStarted(){
        // Do nothing
    }
    
    func attributeOperationFinished(){
        // Do nothing
    }
}

class MockBlePsFtpClient: BlePsFtpClient {
    var requestCalls: [Data] = []
    var requestReturnValues: [Single<Data>] = []
    var requestReturnValueClosure: ((Data) -> Single<Data>)?
    var requestReturnValue: Single<Data>?
    var directoryContentReturnValue: Single<Data>?
    
    var writeCalls: [(header: NSData, data: InputStream)] = []
    var writeReturnValue: Observable<UInt>?
    
    var sendNotificationCalls: [(notification: Int, parameters: NSData?)] = []
    var sendNotificationReturnValue: Completable?
    
    var receiveNotificationCalls: [(notification: Int, parameters: [Data], compressed: Bool)] = []
    var receiveNotificationReturnValue: Completable?

    public override func request(_ header: Data) -> Single<NSData> {
        requestCalls.append(header)

        if !requestReturnValues.isEmpty {
            return requestReturnValues.removeFirst().map { NSData(data: $0) }
        }
        
        if let returnValue = requestReturnValueClosure {
            return returnValue(header).map { NSData(data: $0) }
        }
        return (requestReturnValue ?? Single.just(Data())).map { NSData(data: $0) }
    }
    
    public override func write(_ header: NSData, data: InputStream) -> Observable<UInt> {
        writeCalls.append((header, data))
        return writeReturnValue ?? Observable.empty()
    }
    
    public override func sendNotification(_ id: Int, parameters: NSData?) -> Completable {
        sendNotificationCalls.append((id, parameters))
        return sendNotificationReturnValue ?? Completable.empty()
    }
    
    override func waitNotification() -> Observable<PsFtpNotification> {
        return Observable.from(receiveNotificationCalls)
            .map { (id, arrayOfData, compressed) in
                switch id {
                case Protocol_PbPFtpDevToHostNotification.restApiEvent.rawValue:
                    var event: Protocol_PbPftpDHRestApiEvent = Protocol_PbPftpDHRestApiEvent()
                    event.uncompressed = compressed == false
                    event.event = arrayOfData
                    let notification = PsFtpNotification()
                    notification.id = Int32(id)
                    notification.parameters = NSMutableData(data: try! event.serializedData())
                    return notification
                    // Add D2H notification cases as needed
                default:
                    let notification = PsFtpNotification()
                    notification.id = Int32(id)
                    notification.parameters = NSMutableData(data: arrayOfData.last ?? Data())
                    return notification
                }
            }
    }
}
