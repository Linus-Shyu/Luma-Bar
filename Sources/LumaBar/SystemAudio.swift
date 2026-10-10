import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import Combine
import CommonCrypto
import Contacts
import CoreAudio
import CoreText
import CoreWLAN
import Darwin
import IOKit.ps
import PDFKit
import QuartzCore
import ScreenCaptureKit
import Security
import SQLite3
import Speech
import SwiftUI


@MainActor
enum SystemAudioController {
    static func outputVolume() -> Double? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }

        var address = volumePropertyAddress()
        if AudioObjectHasProperty(deviceID, &address) {
            var volume = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
            if status == noErr {
                return Double(volume)
            }
        }

        var channelVolumes: [Float32] = []
        for channel in [UInt32(1), UInt32(2)] {
            var channelAddress = channelVolumePropertyAddress(channel: channel)
            guard AudioObjectHasProperty(deviceID, &channelAddress) else { continue }

            var volume = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &channelAddress, 0, nil, &size, &volume)
            if status == noErr {
                channelVolumes.append(volume)
            }
        }

        guard !channelVolumes.isEmpty else { return nil }
        let total = channelVolumes.reduce(Float32(0), +)
        return Double(total / Float32(channelVolumes.count))
    }

    @discardableResult
    static func setOutputVolume(_ value: Double) -> Bool {
        let clampedValue = min(1, max(0, value))
        return setDeviceVolume(Float32(clampedValue))
    }

    private static func defaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    private static func setDeviceVolume(_ volume: Float32) -> Bool {
        guard let deviceID = defaultOutputDeviceID() else { return false }

        var address = volumePropertyAddress()
        var mutableVolume = volume
        if AudioObjectHasProperty(deviceID, &address) {
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &mutableVolume
            )
            if status == noErr {
                return true
            }
        }

        var didSetChannelVolume = false
        for channel in [UInt32(1), UInt32(2)] {
            var channelAddress = channelVolumePropertyAddress(channel: channel)
            guard AudioObjectHasProperty(deviceID, &channelAddress) else { continue }

            var channelVolume = volume
            let status = AudioObjectSetPropertyData(
                deviceID,
                &channelAddress,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &channelVolume
            )
            didSetChannelVolume = didSetChannelVolume || status == noErr
        }

        return didSetChannelVolume
    }

    private static func volumePropertyAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func channelVolumePropertyAddress(channel: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
    }

}

