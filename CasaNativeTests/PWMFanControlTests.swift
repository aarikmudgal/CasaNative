import XCTest
@testable import CasaNative

final class PWMFanControlTests: XCTestCase {
    @MainActor
    func testDetectionUpdatesSelectedDutyWithoutRecursiveSetter() async {
        let controller = MockPWMFanController(
            initialStatus: PWMFanStatus(
                ownership: .external,
                backend: .pigpio,
                pin: .gpio18,
                periodNanoseconds: 40_000,
                dutyPercent: 50,
                isEnabled: true,
                isRuntimeAvailable: true,
                requiresReboot: false,
                canRestoreAutomatic: false,
                detail: "Fixture"
            )
        )
        let model = PWMFanScreenModel(controller: controller)

        await model.detectIfNeeded()

        XCTAssertEqual(model.selectedDutyPercent, 50)
    }

    func testSupportedPinsHaveFixedHardwareMappings() {
        XCTAssertEqual(PWMFanGPIOPin.gpio12.function, 4)
        XCTAssertEqual(PWMFanGPIOPin.gpio12.channel, 0)
        XCTAssertEqual(PWMFanGPIOPin.gpio12.physicalHeaderPin, 32)
        XCTAssertEqual(PWMFanGPIOPin.gpio13.function, 4)
        XCTAssertEqual(PWMFanGPIOPin.gpio13.channel, 1)
        XCTAssertEqual(PWMFanGPIOPin.gpio18.function, 2)
        XCTAssertEqual(PWMFanGPIOPin.gpio18.channel, 0)
        XCTAssertEqual(PWMFanGPIOPin.gpio18.physicalHeaderPin, 12)
        XCTAssertEqual(PWMFanGPIOPin.gpio19.function, 2)
        XCTAssertEqual(PWMFanGPIOPin.gpio19.channel, 1)
    }

#if false // V2 parser tests retired with the excluded V2 wire format.
    func testAbsentProbeIsProvisionable() throws {
        let status = try PWMFanProbeParserV2.parse(probe())
        XCTAssertEqual(status.ownership, .absent)
        XCTAssertNil(status.backend)
        XCTAssertFalse(status.isRuntimeAvailable)
    }

    func testLegacyFan50SysfsSetupIsAdoptedWithoutOwnership() throws {
        let status = try PWMFanProbeParserV2.parse(probe([
            "overlay": "18:2",
            "legacy_block": "1",
            "legacy_script": "1",
            "legacy_service": "1",
            "sysfs_count": "1",
            "sysfs_pin": "18",
            "sysfs_period": "40000",
            "sysfs_duty": "20000",
            "sysfs_enabled": "1",
        ]))
        XCTAssertEqual(status.ownership, .external)
        XCTAssertEqual(status.backend, .sysfs)
        XCTAssertEqual(status.pin, .gpio18)
        XCTAssertEqual(status.dutyPercent, 50)
        XCTAssertTrue(status.isRuntimeAvailable)
    }

    func testLegacyFan50WithActivePigpioDeterministicallyUsesPigpio() throws {
        let status = try PWMFanProbeParserV2.parse(probe([
            "overlay": "18:2",
            "legacy_block": "1",
            "legacy_script": "1",
            "legacy_service": "1",
            "pigs": "active",
            "pigs_path": "/usr/bin/pigs",
            "pigpio_version": "79",
            "pigpio_pin": "18",
            "pigpio_duty": "500000",
            "pigpio_frequency": "25000",
            "pigpio_mode": "2",
            "sysfs_count": "1",
            "sysfs_pin": "18",
            "sysfs_period": "40000",
            "sysfs_duty": "20000",
            "sysfs_enabled": "1",
        ]))

        XCTAssertEqual(status.ownership, .external)
        XCTAssertEqual(status.backend, .pigpio)
        XCTAssertEqual(status.dutyPercent, 50)
        XCTAssertFalse(status.canRestoreAutomatic)
    }

    func testUnassociatedPWMOutputsFailClosed() throws {
        let pigpio = try PWMFanProbeParserV2.parse(probe([
            "pigs": "active",
            "pigs_path": "/usr/bin/pigs",
            "pigpio_version": "79",
            "pigpio_pin": "18",
            "pigpio_duty": "500000",
            "pigpio_frequency": "25000",
            "pigpio_mode": "2",
        ]))
        let sysfs = try PWMFanProbeParserV2.parse(probe([
            "overlay": "18:2",
            "sysfs_count": "1",
            "sysfs_pin": "18",
            "sysfs_period": "40000",
            "sysfs_duty": "20000",
            "sysfs_enabled": "1",
        ]))

        XCTAssertEqual(pigpio.ownership, .conflict)
        XCTAssertEqual(sysfs.ownership, .conflict)
        XCTAssertFalse(pigpio.isRuntimeAvailable)
    }

    func testPigpioManualOverrideAndLiveGPIOFanCanRestoreAutomatic() throws {
        let status = try PWMFanProbeParserV2.parse(probe([
            "gpio_fan_config": "1",
            "gpio_fan_config_pin": "18",
            "gpio_fan_live": "1",
            "gpio_fan_live_pin": "18",
            "pigs": "active",
            "pigs_path": "/usr/bin/pigs",
            "pigpio_version": "79",
            "pigpio_pin": "18",
            "pigpio_duty": "250000",
            "pigpio_frequency": "25000",
            "pigpio_mode": "2",
        ]))
        XCTAssertEqual(status.ownership, .external)
        XCTAssertEqual(status.backend, .pigpio)
        XCTAssertEqual(status.pin, .gpio18)
        XCTAssertEqual(status.periodNanoseconds, 40_000)
        XCTAssertEqual(status.dutyPercent, 25)
        XCTAssertTrue(status.canRestoreAutomatic)
    }

    func testGPIOFanConfigWithoutLiveDeviceCannotRestore() throws {
        let status = try PWMFanProbeParserV2.parse(probe([
            "gpio_fan_config": "1",
            "gpio_fan_config_pin": "18",
            "pigs": "active",
            "pigs_path": "/usr/local/bin/pigs",
            "pigpio_version": "80",
            "pigpio_pin": "18",
            "pigpio_duty": "500000",
            "pigpio_frequency": "25000",
            "pigpio_mode": "2",
        ]))
        XCTAssertFalse(status.canRestoreAutomatic)
    }

    func testManagedSetupRequiresAllMarkersAndMatchingRuntime() throws {
        let status = try PWMFanProbeParserV2.parse(probe([
            "overlay": "12:4",
            "managed_block": "1",
            "managed_helper": "1",
            "managed_defaults": "1",
            "managed_service": "1",
            "sysfs_count": "1",
            "sysfs_pin": "12",
            "sysfs_period": "40000",
            "sysfs_duty": "30000",
            "sysfs_enabled": "1",
        ]))
        XCTAssertEqual(status.ownership, .managed)
        XCTAssertEqual(status.backend, .sysfs)
        XCTAssertEqual(status.pin, .gpio12)
        XCTAssertEqual(status.dutyPercent, 75)
    }

    func testPartialOwnershipMarkersFailClosedAsConflict() throws {
        let status = try PWMFanProbeParserV2.parse(probe([
            "overlay": "18:2",
            "managed_block": "1",
        ]))
        XCTAssertEqual(status.ownership, .conflict)
        XCTAssertFalse(status.isRuntimeAvailable)
    }

    func testUnsupportedOverlayPairFailsClosedAsConflict() throws {
        let status = try PWMFanProbeParserV2.parse(probe([
            "overlay": "18:4",
        ]))
        XCTAssertEqual(status.ownership, .conflict)
    }

    func testDuplicateAndUnknownRecordsAreRejected() {
        XCTAssertThrowsError(
            try PWMFanProbeParserV2.parse(probe() + "config\t1\n")
        )
        XCTAssertThrowsError(
            try PWMFanProbeParserV2.parse(probe() + "surprise\t1\n")
        )
    }

    func testOldOrMalformedPigpioStateIsRejected() {
        XCTAssertThrowsError(try PWMFanProbeParserV2.parse(probe([
            "pigs": "active",
            "pigs_path": "/usr/bin/pigs",
            "pigpio_version": "78",
            "pigpio_pin": "18",
            "pigpio_duty": "500000",
            "pigpio_frequency": "25000",
            "pigpio_mode": "2",
        ])))
        XCTAssertThrowsError(try PWMFanProbeParserV2.parse(probe([
            "pigs": "active",
            "pigs_path": "/usr/bin/pigs",
            "pigpio_version": "79",
            "pigpio_pin": "18;reboot",
            "pigpio_duty": "500000",
            "pigpio_frequency": "25000",
            "pigpio_mode": "2",
        ])))
    }
#endif

    func testPigpioApplyUsesOnlyValidatedIntegers() {
        let request = PWMFanScripts.pigpioApply(
            pin: .gpio18,
            dutyPercent: 50
        )
        XCTAssertTrue(request.command.contains("/bin/sh -c"))
        XCTAssertTrue(request.command.hasPrefix("/usr/bin/timeout"))
        XCTAssertTrue(request.command.contains(" 6s /bin/sh"))
        XCTAssertEqual(request.timeoutSeconds, 10)
        XCTAssertFalse(request.command.contains("500000"))
        XCTAssertTrue(request.standardInput.isEmpty)
        XCTAssertTrue(
            decodedPrivilegedScript(request).hasPrefix(
                "PATH=/usr/sbin:/usr/bin:/sbin:/bin\nexport PATH\n"
            )
        )
    }

    func testPrivilegedPasswordOnlyAppearsInStandardInput() {
        let request = PWMFanScripts.privileged(
            script: "printf ok\n",
            password: "secret value"
        )
        XCTAssertFalse(request.command.contains("secret"))
        XCTAssertEqual(
            String(decoding: request.standardInput, as: UTF8.self),
            "secret value\n"
        )
        XCTAssertNil(request.standardInput.range(of: Data("printf ok".utf8)))
        XCTAssertTrue(request.command.contains("/usr/bin/timeout"))
        XCTAssertFalse(request.command.contains("printf ok"))
        XCTAssertTrue(request.command.hasPrefix("/usr/bin/sudo -S"))
        XCTAssertTrue(
            decodedPrivilegedScript(request).hasPrefix(
                "PATH=/usr/sbin:/usr/bin:/sbin:/bin\nexport PATH\n"
            )
        )
        XCTAssertEqual(
            PWMFanScripts.sudoNonInteractiveCheck.command,
            "/usr/bin/sudo -n /usr/bin/true"
        )
    }

    func testV3DetectionScriptIsPrivilegedReadOnly() {
        let request = PWMFanScripts.privilegedReadOnlyDetection(
            password: "secret"
        )
        let script = decodedPrivilegedScript(request)

        XCTAssertTrue(request.command.hasPrefix("/usr/bin/sudo -S"))
        XCTAssertTrue(script.contains("flock -s -w 3"))
        XCTAssertTrue(script.contains("systemctl is-enabled"))
        XCTAssertFalse(script.contains("systemctl enable"))
        XCTAssertFalse(script.contains("systemctl disable"))
        XCTAssertFalse(script.contains("systemctl start"))
        XCTAssertFalse(script.contains("systemctl stop"))
        XCTAssertFalse(script.contains("systemctl restart"))
        XCTAssertFalse(script.contains("modprobe"))
        XCTAssertFalse(script.contains(" > /sys/"))
        XCTAssertFalse(script.contains(" hp "))
    }

#if false // V1 managed lifecycle generators are excluded from production.
    func testProvisionUsesFixedOwnedPathsBackupAndNoReboot() {
        let script = PWMFanScripts.provision(
            pin: .gpio19,
            initialDutyPercent: 45
        )
        XCTAssertTrue(script.contains("dtoverlay=pwm,pin=19,func=2"))
        XCTAssertTrue(script.contains("casanative-pwm-fan.bak"))
        XCTAssertTrue(script.contains("/usr/local/sbin/casanative-pwm-fan"))
        XCTAssertTrue(script.contains("systemctl enable casanative-pwm-fan.service"))
        XCTAssertFalse(script.contains("reboot"))
        XCTAssertTrue(script.contains("test ! -e /usr/local/bin/fan50.sh"))
        XCTAssertTrue(script.contains("A supported GPIO is already in use"))
        XCTAssertTrue(script.contains("An exported PWM channel already exists"))
    }

    func testManagedPersistenceStagesThenAtomicallyRestoresOldInode() {
        let script = PWMFanScripts.managedApply(
            pin: .gpio18,
            dutyPercent: 50,
            persist: true
        )

        XCTAssertTrue(script.contains("ln /etc/default/casanative-pwm-fan \"$saved\""))
        XCTAssertTrue(script.contains("mv \"$staged\" /etc/default/casanative-pwm-fan"))
        XCTAssertTrue(script.contains("mv -f \"$saved\" /etc/default/casanative-pwm-fan"))
        XCTAssertFalse(script.contains("cp -p \"$saved\""))
    }
#endif

#if false // V2 ambiguity fixtures retired; V3 has equivalent fail-closed coverage.
    func testAmbiguousProbeStatesFailClosedAsConflicts() throws {
        for changes in [
            ["pigs": "ambiguous", "pigs_path": "/usr/bin/pigs"],
            ["sysfs_count": "x"],
            ["gpio_fan_live": "x"],
            ["managed_helper": "x"],
        ] {
            XCTAssertEqual(
                try PWMFanProbeParserV2.parse(probe(changes)).ownership,
                .conflict
            )
        }
    }
#endif

    func testOwnedSysfsAndGPIOFanAlwaysConflict() throws {
        let legacyApply = PWMFanScripts.externalSysfsApply(
            pin: .gpio18,
            dutyPercent: 50
        )
        let managedApply = PWMFanScripts.managedLifecycleApply(
            source: .defaultConfiguration(pin: .gpio18),
            dutyPercent: 50,
            persist: false
        )
        XCTAssertTrue(legacyApply.contains("Automatic gpio-fan and Linux PWM"))
        XCTAssertTrue(managedApply.contains("verify_no_gpiofan_live"))
        XCTAssertTrue(managedApply.contains("verify_no_pigpio"))
    }

    func testSuccessfulApplyThenFailedRefreshIsChangedButUnverified() async throws {
        let initial = v3Probe([
            "disk_state": "external_pwm",
            "disk_pin": "18",
            "disk_duty": "50",
            "live_state": "manual",
            "live_pin": "18",
            "live_duty": "50",
            "live_period": "40000",
            "live_enabled": "1",
            "legacy": "exact",
            "pigs": "active",
            "pigs_path": "/usr/bin/pigs",
            "pigpio_version": "79",
            "pigpio_pin": "18",
            "pigpio_duty": "500000",
            "pigpio_frequency": "25000",
            "pigpio_mode": "2",
        ])
        let executor = ScriptedPWMSSHExecutor(results: [
            result(output: initial),
            result(),
            result(error: "probe unavailable", exitStatus: 1),
        ])
        let controller = try await makeController(
            executor: executor,
            password: "secret"
        )

        let status = try await controller.apply(
            dutyPercent: 45,
            persist: false
        )

        XCTAssertEqual(status.verification, .changedButUnverified)
        XCTAssertEqual(status.dutyPercent, 45)
        let requests = await executor.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertFalse(requests[1].command.contains("sudo"))
    }

    func testRemoteTimeoutExitStatusesAreChangedButUnverified() async throws {
        for exitStatus in [124, 137] {
            let executor = ScriptedPWMSSHExecutor(results: [
                result(output: v3Probe([
                    "disk_state": "external_pwm",
                    "disk_pin": "18",
                    "disk_duty": "50",
                    "live_state": "manual",
                    "live_pin": "18",
                    "live_duty": "50",
                    "live_period": "40000",
                    "live_enabled": "1",
                    "legacy": "exact",
                ])),
                result(),
                result(error: "password timeout", exitStatus: exitStatus),
            ])
            let controller = try await makeController(
                executor: executor,
                password: "secret"
            )

            let status = try await controller.apply(
                dutyPercent: 45,
                persist: false
            )

            XCTAssertEqual(status.verification, .changedButUnverified)
            XCTAssertFalse(status.isRuntimeAvailable)
            let requests = await executor.requests
            XCTAssertEqual(requests.count, 3)
            XCTAssertTrue(requests[2].command.hasPrefix("/usr/bin/sudo -n"))
        }
    }

    func testNonAbsentProvisionSendsNoPrivilegedRequest() async throws {
        let executor = ScriptedPWMSSHExecutor(results: [result(output: v3Probe([
            "disk_state": "external_gpiofan",
            "disk_pin": "18",
            "disk_temp": "55",
            "disk_hyst": "10",
            "live_state": "automatic",
            "live_pin": "18",
            "live_temp": "55",
            "live_hyst": "10",
            "automatic_demand": "off",
        ]))])
        let controller = try await makeController(
            executor: executor,
            password: "secret"
        )

        do {
            _ = try await controller.provision(
                pin: .gpio18,
                initialDutyPercent: 50
            )
            XCTFail("Expected setupAlreadyExists")
        } catch let error as PWMFanError {
            XCTAssertEqual(error, .setupAlreadyExists)
        }

        let requests = await executor.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].command.hasPrefix("/usr/bin/sudo"))
        let detection = decodedPrivilegedScript(requests[0])
        XCTAssertTrue(detection.contains("flock -s -w 3"))
        XCTAssertFalse(detection.contains("systemctl enable"))
    }

    func testExternalRestoreVerifiesExactGPIOFanPolicyBeforeAndAfterReload() async throws {
        let initial = v3Probe([
            "disk_state": "external_gpiofan",
            "disk_pin": "18",
            "disk_temp": "60",
            "disk_hyst": "15",
            "live_state": "automatic",
            "live_pin": "18",
            "live_temp": "60",
            "live_hyst": "15",
            "automatic_demand": "full",
            "pigs": "active",
            "pigs_path": "/usr/bin/pigs",
            "pigpio_version": "79",
            "pigpio_pin": "18",
            "pigpio_duty": "500000",
            "pigpio_frequency": "25000",
            "pigpio_mode": "2",
        ])
        let restored = v3Probe([
            "disk_state": "external_gpiofan",
            "disk_pin": "18",
            "disk_temp": "60",
            "disk_hyst": "15",
            "live_state": "automatic",
            "live_pin": "18",
            "live_temp": "60",
            "live_hyst": "15",
            "automatic_demand": "off",
        ])
        let executor = ScriptedPWMSSHExecutor(results: [
            result(output: initial), result(), result(), result(output: restored),
        ])
        let controller = try await makeController(
            executor: executor,
            password: "secret"
        )

        let status = try await controller.restoreAutomatic()

        XCTAssertEqual(status.verification, .verified)
        XCTAssertEqual(status.ownership, .external)
        XCTAssertEqual(status.backend, .gpioFan)
        XCTAssertEqual(status.activeConfiguration?.turnOnCelsius, 60)
        XCTAssertEqual(status.automaticDemand, .off)
        let requests = await executor.requests
        XCTAssertEqual(requests.count, 4)
        let script = decodedPrivilegedScript(requests[2])
        XCTAssertEqual(
            script.components(separatedBy: "verify_automatic_live 18 60 15").count - 1,
            2
        )
        XCTAssertTrue(script.contains("gpio-fan,speed-map"))
        XCTAssertTrue(script.contains("cooling-device"))
        XCTAssertTrue(script.contains("/cdev*"))
        XCTAssertTrue(script.contains("18|60000|15000"))
        XCTAssertTrue(script.contains("trap rollback EXIT"))
    }

    func testNewlinePasswordRejectedBeforePrivilegedMutation() async throws {
        let executor = ScriptedPWMSSHExecutor(results: [])
        let controller = try await makeController(
            executor: executor,
            password: "bad\npassword"
        )

        do {
            _ = try await controller.apply(
                dutyPercent: 45,
                persist: false
            )
            XCTFail("Expected invalidPrivilegedPassword")
        } catch let error as PWMFanError {
            XCTAssertEqual(error, .invalidPrivilegedPassword)
        }

        let requests = await executor.requests
        XCTAssertEqual(requests.count, 0)
        XCTAssertFalse(requests.contains { $0.command.contains("sudo -S") })
    }

    func testV3AutomaticPolicyValidationAndSafeDefaults() throws {
        let value = PWMFanAutomaticConfiguration.defaultConfiguration(
            pin: .gpio18
        )
        XCTAssertEqual(value.turnOnCelsius, 55)
        XCTAssertEqual(value.hysteresisCelsius, 10)
        XCTAssertEqual(value.turnOffCelsius, 45)
        XCTAssertThrowsError(
            try PWMFanAutomaticConfiguration(
                pin: .gpio18,
                turnOnCelsius: 39,
                hysteresisCelsius: 10
            )
        )
        XCTAssertThrowsError(
            try PWMFanAutomaticConfiguration(
                pin: .gpio18,
                turnOnCelsius: 40,
                hysteresisCelsius: 15
            )
        )
        XCTAssertEqual(
            PWMFanManualConfiguration.defaultConfiguration(
                pin: .gpio18
            ).dutyPercent,
            50
        )
    }

    func testV3ExactCanonicalManagedBlocks() throws {
        let manual = PWMFanConfiguration.manual(
            try PWMFanManualConfiguration(pin: .gpio13, dutyPercent: 45)
        )
        let automatic = PWMFanConfiguration.automatic(
            try PWMFanAutomaticConfiguration(
                pin: .gpio19,
                turnOnCelsius: 60,
                hysteresisCelsius: 15
            )
        )

        XCTAssertEqual(
            PWMFanManagedLifecycleScripts.block(for: manual),
            "# BEGIN CasaNative PWM Fan\ndtoverlay=pwm,pin=13,func=4\n# END CasaNative PWM Fan"
        )
        XCTAssertEqual(
            PWMFanManagedLifecycleScripts.block(for: automatic),
            "# BEGIN CasaNative GPIO Fan\ndtoverlay=gpio-fan,gpiopin=19,temp=60000,hyst=15000\n# END CasaNative GPIO Fan"
        )
    }

    func testV3StableManualUsesOnlyExactLiveEvidence() throws {
        let status = try PWMFanProbeParser.parse(v3Probe([
            "managed_files": "exact",
            "disk_state": "managed_manual",
            "disk_pin": "18",
            "disk_duty": "50",
            "live_state": "manual",
            "live_pin": "18",
            "live_duty": "50",
            "live_period": "40000",
            "live_enabled": "1",
        ]))

        XCTAssertEqual(status.ownership, .managed)
        XCTAssertEqual(status.backend, .sysfs)
        XCTAssertEqual(status.pin, .gpio18)
        XCTAssertEqual(status.dutyPercent, 50)
        XCTAssertNil(status.transition)
        XCTAssertFalse(status.recoveryRequired)
    }

    func testV3StableAutomaticReportsDemandNotPhysicalSpin() throws {
        let status = try PWMFanProbeParser.parse(v3Probe([
            "managed_files": "exact",
            "disk_state": "managed_automatic",
            "disk_pin": "12",
            "disk_temp": "55",
            "disk_hyst": "10",
            "live_state": "automatic",
            "live_pin": "12",
            "live_temp": "55",
            "live_hyst": "10",
            "automatic_demand": "full",
        ]))

        XCTAssertEqual(status.backend, .gpioFan)
        XCTAssertEqual(status.pin, .gpio12)
        XCTAssertNil(status.dutyPercent)
        XCTAssertEqual(status.automaticDemand, .full)
        XCTAssertFalse(status.detail.localizedCaseInsensitiveContains("spinning"))
        XCTAssertFalse(status.detail.localizedCaseInsensitiveContains("rpm"))
    }

    func testV3PigpioOverrideRetainsExactAutomaticRestorePolicy() throws {
        let status = try PWMFanProbeParser.parse(v3Probe([
            "disk_state": "external_gpiofan",
            "disk_pin": "18",
            "disk_temp": "60",
            "disk_hyst": "15",
            "live_state": "automatic",
            "live_pin": "18",
            "live_temp": "60",
            "live_hyst": "15",
            "automatic_demand": "off",
            "pigs": "active",
            "pigs_path": "/usr/bin/pigs",
            "pigpio_version": "79",
            "pigpio_pin": "18",
            "pigpio_duty": "500000",
            "pigpio_frequency": "25000",
            "pigpio_mode": "2",
        ]))

        XCTAssertEqual(status.backend, .pigpio)
        XCTAssertTrue(status.canRestoreAutomatic)
        XCTAssertEqual(
            status.automaticRestoreConfiguration,
            try PWMFanAutomaticConfiguration(
                pin: .gpio18,
                turnOnCelsius: 60,
                hysteresisCelsius: 15
            )
        )
    }

    func testV3SamePinAutomaticPolicyGenerationsStayDistinct() throws {
        let source: [String: String] = [
            "managed_files": "exact",
            "disk_state": "managed_automatic",
            "disk_pin": "18",
            "disk_temp": "60",
            "disk_hyst": "10",
            "live_state": "automatic",
            "live_pin": "18",
            "live_temp": "55",
            "live_hyst": "10",
            "automatic_demand": "off",
            "transition": "prepared",
            "journal_phase": "prepared",
            "transition_kind": "change",
            "transition_requirement": "reboot",
            "source_state": "automatic",
            "source_pin": "18",
            "source_temp": "55",
            "source_hyst": "10",
            "target_state": "automatic",
            "target_pin": "18",
            "target_temp": "60",
            "target_hyst": "10",
        ]
        let prepared = try PWMFanProbeParser.parse(v3Probe(source))
        XCTAssertFalse(prepared.recoveryRequired)
        XCTAssertEqual(prepared.activeConfiguration?.turnOnCelsius, 55)
        XCTAssertEqual(prepared.pendingConfiguration?.turnOnCelsius, 60)

        var interrupted = source
        interrupted["disk_temp"] = "55"
        interrupted["recovery"] = "1"
        interrupted["recovery_action"] = "cancelPreparedChange"
        let recovery = try PWMFanProbeParser.parse(v3Probe(interrupted))
        XCTAssertTrue(recovery.recoveryRequired)
        XCTAssertEqual(recovery.recoveryAction, .cancelPreparedChange)

        let detection = PWMFanManagedLifecycleScripts.detectionShell
        XCTAssertTrue(detection.contains("[ \"$disk_temp\" = \"$source_temp\" ]"))
        XCTAssertTrue(detection.contains("[ \"$disk_hyst\" = \"$source_hyst\" ]"))
        XCTAssertTrue(detection.contains("matches_disk_generation \"$target_state\" \"$target_pin\" \"$target_temp\" \"$target_hyst\""))
    }

    func testV3PreparedAndBootedPhasesUseSourceThenTargetLiveTruth() throws {
        let base: [String: String] = [
            "managed_files": "exact",
            "disk_state": "managed_automatic",
            "disk_pin": "18",
            "disk_temp": "55",
            "disk_hyst": "10",
            "transition_kind": "change",
            "journal_phase": "prepared",
            "transition_requirement": "reboot",
            "source_state": "manual",
            "source_pin": "18",
            "source_duty": "50",
            "target_state": "automatic",
            "target_pin": "18",
            "target_temp": "55",
            "target_hyst": "10",
        ]
        let prepared = try PWMFanProbeParser.parse(v3Probe(base.merging([
            "transition": "prepared",
            "live_state": "manual",
            "live_pin": "18",
            "live_duty": "50",
            "live_period": "40000",
            "live_enabled": "1",
        ]) { _, new in new }))
        let booted = try PWMFanProbeParser.parse(v3Probe(base.merging([
            "transition": "bootedAwaitingConfirmation",
            "live_state": "automatic",
            "live_pin": "18",
            "live_temp": "55",
            "live_hyst": "10",
            "automatic_demand": "off",
        ]) { _, new in new }))

        XCTAssertEqual(prepared.activeConfiguration?.mode, .manual)
        XCTAssertEqual(prepared.pendingConfiguration?.mode, .automatic)
        XCTAssertEqual(prepared.transition?.phase, .prepared)
        XCTAssertEqual(booted.activeConfiguration?.mode, .automatic)
        XCTAssertEqual(
            booted.transition?.phase,
            .bootedAwaitingConfirmation
        )
    }

    func testV3AllTwelvePinMigrationsRequireFullShutdown() throws {
        for source in PWMFanGPIOPin.allCases {
            for target in PWMFanGPIOPin.allCases where target != source {
                let status = try PWMFanProbeParser.parse(v3Probe([
                    "managed_files": "exact",
                    "disk_state": "managed_manual",
                    "disk_pin": "\(target.rawValue)",
                    "disk_duty": "50",
                    "live_state": "manual",
                    "live_pin": "\(source.rawValue)",
                    "live_duty": "50",
                    "live_period": "40000",
                    "live_enabled": "1",
                    "transition": "prepared",
                    "transition_kind": "change",
                    "journal_phase": "prepared",
                    "transition_requirement": "shutdown",
                    "source_state": "manual",
                    "source_pin": "\(source.rawValue)",
                    "source_duty": "50",
                    "target_state": "manual",
                    "target_pin": "\(target.rawValue)",
                    "target_duty": "50",
                ]))
                XCTAssertEqual(status.pin, source)
                XCTAssertEqual(status.pendingConfiguration?.pin, target)
                XCTAssertEqual(
                    status.transition?.requirement,
                    .fullShutdown
                )
            }
        }
    }

    func testV3FreshInstallCanBePreparedForReboot() throws {
        let status = try PWMFanProbeParser.parse(v3Probe([
            "managed_files": "exact",
            "disk_state": "managed_manual",
            "disk_pin": "12",
            "disk_duty": "50",
            "transition": "prepared",
            "transition_kind": "change",
            "journal_phase": "prepared",
            "transition_requirement": "reboot",
            "source_state": "none",
            "target_state": "manual",
            "target_pin": "12",
            "target_duty": "50",
        ]))

        XCTAssertNil(status.activeConfiguration)
        XCTAssertEqual(status.pendingConfiguration?.pin, .gpio12)
        XCTAssertEqual(status.transition?.requirement, .reboot)
    }

    func testV3MixedControllersAndMalformedJournalFailClosed() throws {
        let mixed = try PWMFanProbeParser.parse(v3Probe([
            "live_state": "invalid",
        ]))
        XCTAssertEqual(mixed.ownership, .conflict)

        var duplicate = v3Probe()
        duplicate += "config\t1\n"
        XCTAssertThrowsError(try PWMFanProbeParser.parse(duplicate))
        XCTAssertThrowsError(
            try PWMFanProbeParser.parse(
                v3Probe(["transition": "prepared"])
            )
        )
    }

    func testV3RecoveryRetainsPhaseAppropriateTransition() throws {
        let status = try PWMFanProbeParser.parse(v3Probe([
            "recovery": "1",
            "transition": "prepared",
            "transition_kind": "change",
            "journal_phase": "prepared",
            "transition_requirement": "reboot",
            "source_state": "manual",
            "source_pin": "18",
            "source_duty": "50",
            "target_state": "automatic",
            "target_pin": "18",
            "target_temp": "55",
            "target_hyst": "10",
        ]))

        XCTAssertEqual(status.ownership, .conflict)
        XCTAssertTrue(status.recoveryRequired)
        XCTAssertEqual(status.transition?.phase, .prepared)
    }

    func testV3InterruptedPrepareExposesOnlyCancelableRecovery() throws {
        let status = try PWMFanProbeParser.parse(v3Probe([
            "recovery": "1",
            "transition": "prepared",
            "journal_phase": "prepared",
            "recovery_action": "cancelPreparedChange",
            "transition_kind": "change",
            "transition_requirement": "reboot",
            "source_state": "manual",
            "source_pin": "18",
            "source_duty": "50",
            "target_state": "automatic",
            "target_pin": "18",
            "target_temp": "55",
            "target_hyst": "10",
        ]))

        XCTAssertTrue(status.recoveryRequired)
        XCTAssertEqual(status.recoveryAction, .cancelPreparedChange)
        XCTAssertEqual(status.transition?.phase, .prepared)
    }

    func testV3InterruptedRollbackPreparationHasDedicatedRecovery() throws {
        let status = try PWMFanProbeParser.parse(v3Probe([
            "recovery": "1",
            "recovery_action": "completeRollbackPreparation",
            "managed_files": "exact",
            "disk_state": "managed_automatic",
            "disk_pin": "18",
            "disk_temp": "60",
            "disk_hyst": "10",
            "live_state": "automatic",
            "live_pin": "18",
            "live_temp": "60",
            "live_hyst": "10",
            "automatic_demand": "off",
            "transition": "prepared",
            "journal_phase": "prepared",
            "transition_kind": "rollback",
            "transition_requirement": "reboot",
            "source_state": "automatic",
            "source_pin": "18",
            "source_temp": "60",
            "source_hyst": "10",
            "target_state": "automatic",
            "target_pin": "18",
            "target_temp": "55",
            "target_hyst": "10",
        ]))

        XCTAssertTrue(status.recoveryRequired)
        XCTAssertEqual(status.recoveryAction, .completeRollbackPreparation)
        XCTAssertEqual(status.transition?.kind, .rollback)
        let script = PWMFanScripts.completeRollbackPreparation(
            transition: try XCTUnwrap(status.transition)
        )
        XCTAssertTrue(script.contains("prepared:enabled|prepared:disabled"))
        XCTAssertTrue(script.contains("if block_start="))
        XCTAssertFalse(script.contains("write_journal '"))
        XCTAssertTrue(script.contains("verify_automatic_live 18 60 10"))
    }

    func testV3InterruptedRollbackControllerResumesExistingJournal() async throws {
        let base: [String: String] = [
            "managed_files": "exact",
            "live_state": "automatic",
            "live_pin": "18",
            "live_temp": "60",
            "live_hyst": "10",
            "automatic_demand": "off",
            "transition": "prepared",
            "journal_phase": "prepared",
            "transition_kind": "rollback",
            "transition_requirement": "reboot",
            "source_state": "automatic",
            "source_pin": "18",
            "source_temp": "60",
            "source_hyst": "10",
            "target_state": "automatic",
            "target_pin": "18",
            "target_temp": "55",
            "target_hyst": "10",
        ]
        let recovery = v3Probe(base.merging([
            "recovery": "1",
            "recovery_action": "completeRollbackPreparation",
            "disk_state": "managed_automatic",
            "disk_pin": "18",
            "disk_temp": "60",
            "disk_hyst": "10",
        ]) { _, new in new })
        let prepared = v3Probe(base.merging([
            "disk_state": "managed_automatic",
            "disk_pin": "18",
            "disk_temp": "55",
            "disk_hyst": "10",
        ]) { _, new in new })
        let executor = ScriptedPWMSSHExecutor(results: [
            result(output: recovery), result(), result(), result(output: prepared),
        ])
        let controller = try await makeController(
            executor: executor,
            password: "secret"
        )

        let status = try await controller.prepareRollback()

        XCTAssertEqual(status.verification, .verified)
        XCTAssertFalse(status.recoveryRequired)
        XCTAssertEqual(status.transition?.kind, .rollback)
        XCTAssertEqual(status.pendingConfiguration?.turnOnCelsius, 55)
        let requests = await executor.requests
        XCTAssertEqual(requests.count, 4)
        let script = decodedPrivilegedScript(requests[2])
        XCTAssertFalse(script.contains("write_journal '"))
        XCTAssertTrue(script.contains("publish_replace"))
    }

    func testV3BootedUninstallCanPrepareFullShutdownRollback() async throws {
        let booted = v3Probe([
            "managed_files": "exact",
            "transition": "bootedAwaitingConfirmation",
            "journal_phase": "prepared",
            "transition_kind": "uninstall",
            "transition_requirement": "shutdown",
            "source_state": "manual",
            "source_pin": "18",
            "source_duty": "50",
            "target_state": "uninstalled",
        ])
        let prepared = v3Probe([
            "managed_files": "exact",
            "disk_state": "managed_manual",
            "disk_pin": "18",
            "disk_duty": "50",
            "transition": "prepared",
            "journal_phase": "prepared",
            "transition_kind": "rollback",
            "transition_requirement": "shutdown",
            "source_state": "none",
            "target_state": "manual",
            "target_pin": "18",
            "target_duty": "50",
        ])
        let parsed = try PWMFanProbeParser.parse(booted)
        XCTAssertNil(parsed.activeConfiguration)
        XCTAssertEqual(parsed.transition?.kind, .uninstall)

        let executor = ScriptedPWMSSHExecutor(results: [
            result(output: booted), result(), result(), result(output: prepared),
        ])
        let controller = try await makeController(
            executor: executor,
            password: "secret"
        )
        let status = try await controller.prepareRollback()

        XCTAssertEqual(status.transition?.kind, .rollback)
        XCTAssertEqual(status.transition?.requirement, .fullShutdown)
        XCTAssertNil(status.activeConfiguration)
        XCTAssertEqual(status.pendingConfiguration?.pin, .gpio18)
        let requests = await executor.requests
        let script = decodedPrivilegedScript(requests[2])
        XCTAssertTrue(script.contains("verify_live_absent"))
        XCTAssertTrue(script.contains("publish_append"))
        XCTAssertFalse(script.contains("systemctl reboot"))
        XCTAssertFalse(script.contains("shutdown -"))
    }

    func testV3BootedFreshProvisionCanRollbackToUninstalled() async throws {
        let booted = v3Probe([
            "managed_files": "exact",
            "disk_state": "managed_manual",
            "disk_pin": "18",
            "disk_duty": "50",
            "live_state": "manual",
            "live_pin": "18",
            "live_duty": "50",
            "live_period": "40000",
            "live_enabled": "1",
            "transition": "bootedAwaitingConfirmation",
            "journal_phase": "prepared",
            "transition_kind": "change",
            "transition_requirement": "reboot",
            "source_state": "none",
            "target_state": "manual",
            "target_pin": "18",
            "target_duty": "50",
        ])
        let prepared = v3Probe([
            "managed_files": "exact",
            "live_state": "manual",
            "live_pin": "18",
            "live_duty": "50",
            "live_period": "40000",
            "live_enabled": "1",
            "transition": "prepared",
            "journal_phase": "prepared",
            "transition_kind": "rollback",
            "transition_requirement": "shutdown",
            "source_state": "manual",
            "source_pin": "18",
            "source_duty": "50",
            "target_state": "uninstalled",
        ])
        let executor = ScriptedPWMSSHExecutor(results: [
            result(output: booted), result(), result(), result(output: prepared),
        ])
        let controller = try await makeController(
            executor: executor,
            password: "secret"
        )
        let status = try await controller.prepareRollback()

        XCTAssertEqual(status.transition?.kind, .rollback)
        XCTAssertEqual(status.transition?.requirement, .fullShutdown)
        XCTAssertEqual(status.activeConfiguration?.pin, .gpio18)
        XCTAssertTrue(status.transition?.target.isUninstall == true)
        let requests = await executor.requests
        let script = decodedPrivilegedScript(requests[2])
        XCTAssertTrue(script.contains("verify_manual_live 18 50"))
        XCTAssertTrue(script.contains("publish_replace"))
        XCTAssertFalse(script.contains("systemctl reboot"))
        XCTAssertFalse(script.contains("shutdown -"))
    }

    func testV3NilGenerationRollbackRecoveryIsIdempotent() throws {
        let manual = PWMFanConfiguration.manual(
            .defaultConfiguration(pin: .gpio18)
        )
        let restore = PWMFanTransitionState(
            source: nil,
            target: .configuration(manual),
            phase: .prepared,
            requirement: .fullShutdown,
            kind: .rollback
        )
        let uninstall = PWMFanTransitionState(
            source: manual,
            target: .uninstalled,
            phase: .prepared,
            requirement: .fullShutdown,
            kind: .rollback
        )

        let restoreScript = PWMFanScripts.completeRollbackPreparation(
            transition: restore
        )
        let uninstallScript = PWMFanScripts.completeRollbackPreparation(
            transition: uninstall
        )
        XCTAssertTrue(restoreScript.contains("publish_append"))
        XCTAssertTrue(restoreScript.contains("verify_live_absent"))
        XCTAssertTrue(uninstallScript.contains("publish_replace"))
        XCTAssertTrue(uninstallScript.contains("verify_manual_live 18 50"))
        for script in [restoreScript, uninstallScript] {
            XCTAssertFalse(script.contains("systemctl reboot"))
            XCTAssertFalse(script.contains("shutdown -"))
            XCTAssertFalse(script.contains("modprobe"))
            XCTAssertFalse(script.contains("> /sys/"))
        }
    }

    func testV3ReverseRollbackJournalsPreserveNilGenerations() throws {
        let manual = PWMFanConfiguration.manual(
            .defaultConfiguration(pin: .gpio18)
        )
        let bootedUninstall = PWMFanTransitionState(
            source: manual,
            target: .uninstalled,
            phase: .bootedAwaitingConfirmation,
            requirement: .fullShutdown,
            kind: .uninstall
        )
        let bootedFreshProvision = PWMFanTransitionState(
            source: nil,
            target: .configuration(manual),
            phase: .bootedAwaitingConfirmation,
            requirement: .reboot,
            kind: .configurationChange
        )

        let cases = [
            (
                PWMFanScripts.prepareRollback(
                    transition: bootedUninstall
                ),
                "SOURCE_MODE=none\n",
                "TARGET_MODE=manual\n"
            ),
            (
                PWMFanScripts.prepareRollback(
                    transition: bootedFreshProvision
                ),
                "SOURCE_MODE=manual\n",
                "TARGET_MODE=uninstalled\n"
            ),
        ]
        for (script, expectedSource, expectedTarget) in cases {
            let journalWrite = try XCTUnwrap(
                script.range(of: "write_journal '", options: .backwards)
            )
            let encodedStart = journalWrite.upperBound
            let encodedEnd = try XCTUnwrap(
                script[encodedStart...].firstIndex(of: "'")
            )
            let data = try XCTUnwrap(
                Data(base64Encoded: String(script[encodedStart..<encodedEnd]))
            )
            let journal = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(journal.contains("KIND=rollback\n"))
            XCTAssertTrue(journal.contains("REQUIREMENT=shutdown\n"))
            XCTAssertTrue(journal.contains(expectedSource))
            XCTAssertTrue(journal.contains(expectedTarget))
            XCTAssertFalse(script.contains("systemctl start"))
            XCTAssertFalse(script.contains("systemctl stop"))
            XCTAssertFalse(script.contains("systemctl restart"))
        }
    }

    func testV3AtomicRemovalTombstoneExposesOnlyCleanupRecovery() throws {
        let status = try PWMFanProbeParser.parse(v3Probe([
            "recovery": "1",
            "journal_phase": "removing",
            "recovery_action": "completeStateCleanup",
        ]))

        XCTAssertTrue(status.recoveryRequired)
        XCTAssertNil(status.transition)
        XCTAssertEqual(status.recoveryAction, .completeStateCleanup)
    }

    func testV3DurableFinalizingPhaseExposesDeterministicRecovery() throws {
        let status = try PWMFanProbeParser.parse(v3Probe([
            "recovery": "1",
            "transition": "bootedAwaitingConfirmation",
            "journal_phase": "finalizing",
            "recovery_action": "finalizePreparedChange",
            "transition_kind": "change",
            "transition_requirement": "reboot",
            "source_state": "manual",
            "source_pin": "18",
            "source_duty": "50",
            "target_state": "automatic",
            "target_pin": "18",
            "target_temp": "55",
            "target_hyst": "10",
        ]))

        XCTAssertTrue(status.recoveryRequired)
        XCTAssertEqual(status.recoveryAction, .finalizePreparedChange)
        XCTAssertEqual(
            status.transition?.phase,
            .bootedAwaitingConfirmation
        )
    }

    func testV3LegacyHybridUsesPigpioWithoutTakingOwnership() throws {
        let status = try PWMFanProbeParser.parse(v3Probe([
            "disk_state": "external_pwm",
            "disk_pin": "18",
            "disk_duty": "50",
            "live_state": "manual",
            "live_pin": "18",
            "live_duty": "50",
            "live_period": "40000",
            "live_enabled": "1",
            "legacy": "exact",
            "pigs": "active",
            "pigs_path": "/usr/bin/pigs",
            "pigpio_version": "79",
            "pigpio_pin": "18",
            "pigpio_duty": "500000",
            "pigpio_frequency": "25000",
            "pigpio_mode": "2",
        ]))

        XCTAssertEqual(status.ownership, .external)
        XCTAssertEqual(status.backend, .pigpio)
        XCTAssertEqual(status.legacyState, .exactConvertible)
    }

    func testV3TransitionScriptsHaveNoRuntimeActuationOrPackageInstall() throws {
        let manual = PWMFanConfiguration.manual(
            try PWMFanManualConfiguration(pin: .gpio18, dutyPercent: 50)
        )
        let automatic = PWMFanConfiguration.automatic(
            try PWMFanAutomaticConfiguration(
                pin: .gpio18,
                turnOnCelsius: 55,
                hysteresisCelsius: 10
            )
        )
        let transition = PWMFanTransitionState(
            source: manual,
            target: .configuration(automatic),
            phase: .prepared,
            requirement: .reboot,
            kind: .configurationChange
        )
        let scripts = [
            PWMFanScripts.provision(
                configuration: manual,
                requirement: .reboot
            ),
            PWMFanScripts.prepareConfigurationChange(
                source: manual,
                target: automatic,
                requirement: .reboot,
                kind: .configurationChange
            ),
            PWMFanScripts.cancelPreparedChange(transition: transition),
            PWMFanScripts.convertExactLegacyFan50(),
            PWMFanScripts.resolveLegacyBackup(.restore),
            PWMFanScripts.resolveLegacyBackup(.discard),
        ]
        for script in scripts {
            XCTAssertFalse(script.contains("systemctl start"))
            XCTAssertFalse(script.contains("systemctl stop"))
            XCTAssertFalse(script.contains("systemctl restart"))
            XCTAssertFalse(script.contains("systemctl reboot"))
            XCTAssertFalse(script.contains("shutdown -"))
            XCTAssertFalse(script.contains("modprobe"))
            XCTAssertFalse(script.contains("pigs hp"))
            XCTAssertFalse(script.contains("> /sys/"))
            XCTAssertFalse(script.contains("apt-get"))
            XCTAssertFalse(script.contains(" apt "))
            XCTAssertFalse(script.contains(" dnf "))
            XCTAssertFalse(script.contains(" yum "))
            XCTAssertFalse(script.contains(" pip "))
            XCTAssertFalse(script.contains(" curl "))
            XCTAssertFalse(script.contains(" wget "))
            XCTAssertFalse(script.contains("rm -rf"))
        }
    }

    func testV3TransitionJournalIsDurableBeforeConfigPublish() throws {
        let source = PWMFanConfiguration.manual(
            try PWMFanManualConfiguration(pin: .gpio18, dutyPercent: 50)
        )
        let target = PWMFanConfiguration.automatic(
            try PWMFanAutomaticConfiguration(
                pin: .gpio18,
                turnOnCelsius: 60,
                hysteresisCelsius: 10
            )
        )
        let script = PWMFanScripts.prepareConfigurationChange(
            source: source,
            target: target,
            requirement: .reboot,
            kind: .configurationChange
        )
        let journalWrite = try XCTUnwrap(
            script.range(of: "write_journal '", options: .backwards)
        )
        let publish = try XCTUnwrap(
            script.range(
                of: "publish_replace \"$block_start\"",
                options: .backwards
            )
        )

        XCTAssertLessThan(journalWrite.lowerBound, publish.lowerBound)
        XCTAssertTrue(script.contains("flock -x -w 3"))
        XCTAssertTrue(script.contains("chmod 0600"))
        XCTAssertTrue(script.contains("sync -f \"$STATE/journal\""))
        XCTAssertTrue(script.contains("mv -f \"$temporary\" \"$destination\""))
        let encodedStart = journalWrite.upperBound
        let encodedEnd = try XCTUnwrap(
            script[encodedStart...].firstIndex(of: "'")
        )
        let journalData = try XCTUnwrap(
            Data(base64Encoded: String(script[encodedStart..<encodedEnd]))
        )
        let journal = String(decoding: journalData, as: UTF8.self)
        XCTAssertTrue(journal.contains("PREPARED_BOOT_ID=BOOT_ID"))
        XCTAssertTrue(journal.contains("PHASE=prepared"))
    }

    func testV3ManagedApplyUsesLockedFullDefaultsAndRuntimeRollback() throws {
        let source = try PWMFanManualConfiguration(
            pin: .gpio18,
            dutyPercent: 50
        )
        let script = PWMFanScripts.managedLifecycleApply(
            source: source,
            dutyPercent: 45,
            persist: true
        )

        XCTAssertTrue(script.contains("flock -x -w 3"))
        XCTAssertTrue(script.contains("[ ! -e \"$STATE/journal\" ]") && script.contains("[ ! -L \"$STATE/journal\" ]"))
        let encodedTargetDefault = Data("MODE=manual\nPIN=18\nDUTY_PERCENT=45\n".utf8).base64EncodedString()
        XCTAssertTrue(script.contains(encodedTargetDefault))
        XCTAssertTrue(script.contains("apply_manual_runtime 18 45"))
        let journalMarker = try XCTUnwrap(
            script.range(of: "write_journal '", options: .backwards)
        )
        let journalEnd = try XCTUnwrap(
            script[journalMarker.upperBound...].firstIndex(of: "'")
        )
        let journalData = try XCTUnwrap(Data(base64Encoded: String(
            script[journalMarker.upperBound..<journalEnd]
        )))
        let journal = String(decoding: journalData, as: UTF8.self)
        XCTAssertTrue(journal.contains("PHASE=applying"))
        XCTAssertTrue(journal.contains("TARGET_DUTY=45"))
        XCTAssertTrue(script.contains("rm -f \"$STATE/journal\""))
        XCTAssertFalse(script.contains("apply-default.old"))
    }

    func testV3RecoveryMutationsRemainExecutableAfterPowerLossReboot() throws {
        let manual = try PWMFanManualConfiguration(
            pin: .gpio18,
            dutyPercent: 50
        )
        let applyRecovery = PWMFanScripts.managedLifecycleApply(
            source: manual,
            dutyPercent: 45,
            persist: true,
            resume: true
        )
        let legacyRestore = PWMFanScripts.resolveLegacyBackup(.restore)
        let legacyDiscard = PWMFanScripts.resolveLegacyBackup(.discard)

        XCTAssertFalse(applyRecovery.contains("[ \"$current_boot\" = \"$prepared\" ]"))
        for script in [legacyRestore, legacyDiscard] {
            XCTAssertFalse(script.contains("[ \"$(read_boot_id)\" = \"$prepared\" ]"))
            XCTAssertTrue(script.contains("printf '%s\\n' \"$prepared\" | grep -Eq"))
        }
    }

    func testV3BootHelperRequiresConfigAndBootGenerationAgreement() {
        let helper = PWMFanManagedLifecycleScripts.helper

        XCTAssertTrue(helper.contains("[ \"$config_record\" = \"$source_mode|$source_pin\" ]"))
        XCTAssertTrue(helper.contains("[ \"$config_record\" = \"$target_mode|$target_pin\" ] && [ \"$current\" != \"$prepared\" ]"))
        XCTAssertTrue(helper.contains("else\n    exit 0"))
        XCTAssertTrue(helper.contains("case \"$duty\" in ''|*[!0-9]*) duty=100"))
        XCTAssertFalse(helper.contains("source \"$"))
        XCTAssertFalse(helper.contains("eval "))
    }

    func testV3OfficialGPIOFanTopologyIsVerifiedThroughPhandles() {
        let detection = PWMFanManagedLifecycleScripts.detectionShell
        let mutations = PWMFanScripts.finalizePreparedChange(
            transition: PWMFanTransitionState(
                source: .manual(.defaultConfiguration(pin: .gpio18)),
                target: .configuration(
                    .automatic(
                        .defaultConfiguration(pin: .gpio18)
                    )
                ),
                phase: .bootedAwaitingConfirmation,
                requirement: .reboot,
                kind: .configurationChange
            )
        )

        for script in [detection, mutations] {
            XCTAssertTrue(script.contains("gpio-fan,speed-map"))
            XCTAssertTrue(script.contains("#cooling-cells"))
            XCTAssertTrue(script.contains("cooling-device"))
            XCTAssertTrue(script.contains("/trips/"))
            XCTAssertTrue(script.contains("/sys/bus/platform/drivers/gpio-fan"))
            XCTAssertTrue(script.contains("/cdev*"))
            XCTAssertTrue(script.contains("_trip_point"))
            XCTAssertTrue(script.contains("00000000"))
            XCTAssertFalse(script.contains("$cooling/device"))
        }
        XCTAssertFalse(detection.contains("$node/temperature"))
        XCTAssertFalse(detection.contains("$node/hysteresis"))
    }

    func testV3ConfigMutationPreservesUnrelatedBytesAndPublishesAtomically() throws {
        let manual = PWMFanConfiguration.manual(
            try PWMFanManualConfiguration(pin: .gpio12, dutyPercent: 50)
        )
        let script = PWMFanScripts.provision(
            configuration: manual,
            requirement: .reboot
        )

        XCTAssertTrue(script.contains("grep -Eiq '^[[:space:]]*include"))
        XCTAssertTrue(script.contains("[all]"))
        XCTAssertTrue(script.contains("cp -p \"$CFG\" \"$CFG_TMP\""))
        XCTAssertTrue(script.contains("mv \"$CFG_TMP\" \"$CFG\"") || script.contains("mv -f \"$CFG_TMP\" \"$CFG\""))
        XCTAssertTrue(script.contains("sync -f \"${CFG%/*}\""))
        XCTAssertTrue(
            script.contains(
                "[ -f /boot/firmware/config.txt ] && [ ! -L /boot/firmware/config.txt ]"
            )
        )
        XCTAssertTrue(
            script.contains(
                "[ -f /boot/config.txt ] && [ ! -L /boot/config.txt ]"
            )
        )
        XCTAssertTrue(script.contains("/var/lib/.casanative-pwm-fan.new"))
        XCTAssertTrue(script.contains("mv -T \"$stage\" \"$STATE\""))
    }

    func testV3BootConfigPrefersBookwormCanonicalPathWithLegacyFallback() {
        let helper = PWMFanManagedLifecycleScripts.helper
        let detection = PWMFanManagedLifecycleScripts.detectionShell
        let mutation = PWMFanScripts.provision(
            configuration: .manual(.defaultConfiguration(pin: .gpio18)),
            requirement: .reboot
        )

        for script in [helper, detection, mutation] {
            XCTAssertTrue(script.contains("if [ -e /boot/firmware/config.txt ] || [ -L /boot/firmware/config.txt ]"))
            XCTAssertTrue(script.contains("CFG=/boot/firmware/config.txt"))
            XCTAssertTrue(script.contains("elif [ -e /boot/config.txt ] || [ -L /boot/config.txt ]"))
            XCTAssertTrue(script.contains("CFG=/boot/config.txt"))
            XCTAssertFalse(script.contains("[ \"$count\" = 1 ] || exit 75"))
        }
        XCTAssertTrue(helper.contains("[ -f /boot/firmware/config.txt ] && [ ! -L /boot/firmware/config.txt ] || exit 75"))
        XCTAssertTrue(detection.contains("config=0; recovery=1"))
    }

    func testV3DetectionAwkKeepsScalarsAndArraysDistinctForMawk() {
        let detection = PWMFanManagedLifecycleScripts.detectionShell

        XCTAssertTrue(detection.contains("function add(stateValue,pinValue,dutyValue,tempValue,hystValue)"))
        XCTAssertTrue(detection.contains("split(firstLine,manualParts"))
        XCTAssertTrue(detection.contains("split(firstLine,autoParts"))
        XCTAssertTrue(detection.contains("split(trimmed,gpioTokens"))
        XCTAssertTrue(detection.contains("split(trimmed,pwmTokens"))
        XCTAssertFalse(detection.contains("function add(s,p,d,t,h)"))
        XCTAssertFalse(detection.contains("split(a,x"))
        XCTAssertFalse(detection.contains("split(trimmed,a"))
        XCTAssertFalse(detection.contains("p=12; t=55000; h=10000"))
    }

    func testV3StagedStateIsVisibleAndAdoptableAfterPowerLoss() throws {
        let detection = PWMFanManagedLifecycleScripts.detectionShell
        let manual = PWMFanConfiguration.manual(
            try PWMFanManualConfiguration(pin: .gpio18, dutyPercent: 50)
        )
        let cancel = PWMFanScripts.cancelPreparedChange(
            transition: PWMFanTransitionState(
                source: nil,
                target: .configuration(manual),
                phase: .prepared,
                requirement: .reboot,
                kind: .configurationChange
            )
        )

        XCTAssertTrue(detection.contains("STATE_STAGE=/var/lib/.casanative-pwm-fan.new"))
        XCTAssertTrue(detection.contains("stage_recovery=1"))
        XCTAssertTrue(detection.contains("journal_path=\"$STATE_STAGE/journal\""))
        XCTAssertTrue(cancel.contains("adopt_staged_state"))
        XCTAssertTrue(cancel.contains("mv -T \"$STATE_STAGE\" \"$STATE\""))
        XCTAssertTrue(detection.contains("STATE_REMOVAL=/var/lib/.casanative-pwm-fan.removing"))
        XCTAssertTrue(detection.contains("recovery_action=completeStateCleanup"))
        let cleanup = PWMFanScripts.completeStateCleanup()
        XCTAssertTrue(cleanup.contains("recover_retired_state"))
        XCTAssertFalse(cleanup.contains("rm -rf"))
    }

    func testV3LegacyConversionBackupsAreCopiesAndRuntimeUntouched() {
        let conversion = PWMFanScripts.convertExactLegacyFan50()
        let restore = PWMFanScripts.resolveLegacyBackup(.restore)
        let discard = PWMFanScripts.resolveLegacyBackup(.discard)

        XCTAssertTrue(conversion.contains("copy_backup /usr/local/bin/fan50.sh"))
        XCTAssertTrue(conversion.contains("stat -c %h"))
        XCTAssertTrue(conversion.contains("SERVICE_ENABLED="))
        XCTAssertTrue(conversion.contains("verify_manual_live 18 50"))
        XCTAssertTrue(restore.contains("copy_from_backup"))
        XCTAssertTrue(restore.contains("# BEGIN fan50"))
        XCTAssertTrue(discard.contains("legacy-helper"))
        XCTAssertFalse(conversion.contains("systemctl restart"))
        XCTAssertFalse(restore.contains("systemctl restart"))
    }

    func testV3ControllerRejectsMultiAxisChangeBeforeDispatch() async throws {
        let executor = ScriptedPWMSSHExecutor(results: [
            result(output: v3StableManualProbe(pin: .gpio18, duty: 50)),
        ])
        let controller = try await makeController(
            executor: executor,
            password: "secret"
        )
        let target = PWMFanConfiguration.automatic(
            try PWMFanAutomaticConfiguration(
                pin: .gpio12,
                turnOnCelsius: 55,
                hysteresisCelsius: 10
            )
        )

        do {
            _ = try await controller.prepareConfigurationChange(to: target)
            XCTFail("Expected multi-axis rejection")
        } catch let error as PWMFanError {
            guard case .invalidTransition = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let requestCount = await executor.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testV3ManagedApplyRejectsNonPersistentRuntimeMutation() async throws {
        let executor = ScriptedPWMSSHExecutor(results: [
            result(output: v3StableManualProbe(pin: .gpio18, duty: 50)),
        ])
        let controller = try await makeController(
            executor: executor,
            password: "secret"
        )

        do {
            _ = try await controller.apply(dutyPercent: 45, persist: false)
            XCTFail("Expected managed non-persistent Apply rejection")
        } catch let error as PWMFanError {
            guard case .invalidTransition = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let requests = await executor.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testV3RollbackPreflightsTargetBeforeReverseJournal() throws {
        let script = PWMFanScripts.prepareRollback(
            transition: PWMFanTransitionState(
                source: .automatic(.defaultConfiguration(pin: .gpio18)),
                target: .configuration(
                    .manual(.defaultConfiguration(pin: .gpio18))
                ),
                phase: .bootedAwaitingConfirmation,
                requirement: .reboot,
                kind: .configurationChange
            )
        )
        let preflight = try XCTUnwrap(
            script.range(of: "gpio-fan.dtbo", options: .backwards)
        )
        let journal = try XCTUnwrap(
            script.range(of: "write_journal '", options: .backwards)
        )
        XCTAssertLessThan(preflight.lowerBound, journal.lowerBound)
        XCTAssertTrue(script.contains("/sys/class/thermal/thermal_zone*"))
    }

    func testV3JournalSemanticMatrixRejectsImpossibleTransitions() throws {
        let base: [String: String] = [
            "managed_files": "exact",
            "disk_state": "managed_automatic",
            "disk_pin": "12",
            "disk_temp": "60",
            "disk_hyst": "15",
            "live_state": "manual",
            "live_pin": "18",
            "live_duty": "50",
            "live_period": "40000",
            "live_enabled": "1",
            "transition": "prepared",
            "journal_phase": "prepared",
            "transition_kind": "change",
            "transition_requirement": "shutdown",
            "source_state": "manual",
            "source_pin": "18",
            "source_duty": "50",
            "target_state": "automatic",
            "target_pin": "12",
            "target_temp": "60",
            "target_hyst": "15",
        ]
        XCTAssertThrowsError(try PWMFanProbeParser.parse(v3Probe(base)))

        var automaticPinAndPolicy = base
        automaticPinAndPolicy["source_state"] = "automatic"
        automaticPinAndPolicy["source_temp"] = "55"
        automaticPinAndPolicy["source_hyst"] = "10"
        automaticPinAndPolicy["source_duty"] = ""
        automaticPinAndPolicy["live_state"] = "automatic"
        automaticPinAndPolicy["live_temp"] = "55"
        automaticPinAndPolicy["live_hyst"] = "10"
        automaticPinAndPolicy["live_duty"] = ""
        automaticPinAndPolicy["live_period"] = ""
        automaticPinAndPolicy["live_enabled"] = ""
        automaticPinAndPolicy["automatic_demand"] = "off"
        XCTAssertThrowsError(
            try PWMFanProbeParser.parse(v3Probe(automaticPinAndPolicy))
        )

        let shell = PWMFanManagedLifecycleScripts.detectionShell
        XCTAssertTrue(shell.contains("[ \"$source_pin\" = \"$target_pin\" ]"))
        XCTAssertTrue(shell.contains("[ \"$source_duty\" = \"$target_duty\" ]"))
        XCTAssertTrue(shell.contains("[ \"$source_temp\" = \"$target_temp\" ]"))
    }

    func testV3ReservedPartialTempsHaveExactCleanupRecovery() {
        let detection = PWMFanManagedLifecycleScripts.detectionShell
        let cleanup = PWMFanScripts.completeStateCleanup()
        let provision = PWMFanScripts.provision(
            configuration: .manual(.defaultConfiguration(pin: .gpio18)),
            requirement: .reboot
        )

        XCTAssertTrue(detection.contains("stage_complete=0"))
        XCTAssertTrue(detection.contains("partial_temp_recovery=1"))
        XCTAssertTrue(detection.contains("recovery_action=completeStateCleanup"))
        XCTAssertTrue(cleanup.contains("cleanup_partial_stage"))
        XCTAssertTrue(cleanup.contains("cleanup_reserved_temps"))
        XCTAssertTrue(cleanup.contains("journal.tmp"))
        XCTAssertTrue(cleanup.contains(".casanative-pwm-fan.tmp"))
        XCTAssertTrue(provision.contains("interrupted first write"))
        XCTAssertFalse(cleanup.contains("rm -rf"))
    }

    func testV3FixedParentsAndEffectiveUnitsFailClosed() {
        let detection = PWMFanManagedLifecycleScripts.detectionShell
        let transition = PWMFanScripts.prepareConfigurationChange(
            source: .manual(.defaultConfiguration(pin: .gpio18)),
            target: .automatic(.defaultConfiguration(pin: .gpio18)),
            requirement: .reboot,
            kind: .configurationChange
        )
        let conversion = PWMFanScripts.convertExactLegacyFan50()

        for script in [detection, transition, conversion] {
            XCTAssertTrue(script.contains("trusted_parent"))
            XCTAssertTrue(script.contains("/usr/local/sbin"))
            XCTAssertTrue(script.contains("/etc/systemd/system"))
            XCTAssertTrue(script.contains("/var/lib"))
            XCTAssertTrue(script.contains("FragmentPath"))
            XCTAssertTrue(script.contains("DropInPaths"))
        }
        XCTAssertTrue(transition.contains("effective_unit_exact casanative-pwm-fan.service"))
        XCTAssertTrue(conversion.contains("effective_unit_exact fan50.service"))
    }

    func testV3StageAndTombstoneCleanupAreSerialized() {
        let provision = PWMFanScripts.provision(
            configuration: .manual(.defaultConfiguration(pin: .gpio18)),
            requirement: .reboot
        )
        let cleanup = PWMFanScripts.completeStateCleanup()

        XCTAssertTrue(provision.contains("exec 7<>\"$stage/lock\"; flock -x -w 3 7"))
        XCTAssertTrue(provision.contains("flock -u 7; exec 7>&-"))
        XCTAssertTrue(cleanup.contains("exec 7<>\"$STATE_STAGE/lock\"; flock -x -w 3 7"))
        XCTAssertTrue(cleanup.contains("exec 7<>\"$STATE_REMOVAL/lock\"; flock -x -w 3 7"))
        XCTAssertTrue(provision.contains("set -C; : > \"$stage/journal\""))
        XCTAssertTrue(provision.contains("set -C; : > \"$stage/lock\""))
        let stageLock = try? XCTUnwrap(provision.range(of: "exec 7<>\"$stage/lock\"; flock -x -w 3 7"))
        let stageValidation = try? XCTUnwrap(provision.range(of: "for item in \"$stage\"/*"))
        if let stageLock, let stageValidation {
            XCTAssertLessThan(stageLock.lowerBound, stageValidation.lowerBound)
        }
    }

    func testV3ProvisionFailureAfterDispatchIsChangedButUnverified() async throws {
        let executor = ScriptedPWMSSHExecutor(results: [
            result(output: v3Probe()),
            result(),
            result(error: "remote failure", exitStatus: 75),
        ])
        let controller = try await makeController(
            executor: executor,
            password: "secret"
        )
        let status = try await controller.provision(
            configuration: .manual(
                .defaultConfiguration(pin: .gpio18)
            )
        )

        XCTAssertEqual(status.verification, .changedButUnverified)
        XCTAssertTrue(status.recoveryRequired)
        XCTAssertTrue(status.detail.contains("outcome is unknown"))
        let requestCount = await executor.requests.count
        XCTAssertEqual(requestCount, 3)
    }

    func testV3MockLifecycleSupportsPinPrepareAndCancel() async throws {
        let manual = PWMFanConfiguration.manual(
            .defaultConfiguration(pin: .gpio18)
        )
        let initial = PWMFanStatus(
            ownership: .managed,
            backend: .sysfs,
            pin: .gpio18,
            periodNanoseconds: 40_000,
            dutyPercent: 50,
            isEnabled: true,
            isRuntimeAvailable: true,
            requiresReboot: false,
            canRestoreAutomatic: false,
            detail: "Fixture",
            activeConfiguration: manual
        )
        let controller = MockPWMFanController(initialStatus: initial)
        let target = PWMFanConfiguration.manual(
            .defaultConfiguration(pin: .gpio12)
        )

        let prepared = try await controller.prepareConfigurationChange(
            to: target
        )
        XCTAssertEqual(prepared.transition?.requirement, .fullShutdown)
        XCTAssertEqual(prepared.pin, .gpio18)
        let cancelled = try await controller.cancelPreparedChange()
        XCTAssertNil(cancelled.transition)
        XCTAssertEqual(cancelled.pin, .gpio18)
    }

    func testV3MockRejectsRollbackOfRollback() async throws {
        let manual18 = PWMFanConfiguration.manual(
            .defaultConfiguration(pin: .gpio18)
        )
        let manual12 = PWMFanConfiguration.manual(
            .defaultConfiguration(pin: .gpio12)
        )
        let controller = MockPWMFanController(initialStatus: PWMFanStatus(
            ownership: .managed,
            backend: .sysfs,
            pin: .gpio18,
            periodNanoseconds: 40_000,
            dutyPercent: 50,
            isEnabled: true,
            isRuntimeAvailable: true,
            requiresReboot: true,
            canRestoreAutomatic: false,
            detail: "Rollback fixture",
            activeConfiguration: manual18,
            transition: PWMFanTransitionState(
                source: manual12,
                target: .configuration(manual18),
                phase: .bootedAwaitingConfirmation,
                requirement: .fullShutdown,
                kind: .rollback
            )
        ))

        do {
            _ = try await controller.prepareRollback()
            XCTFail("Expected rollback-of-rollback rejection")
        } catch let error as PWMFanError {
            guard case .invalidTransition = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func makeController(
        executor: ScriptedPWMSSHExecutor,
        password: String
    ) async throws -> SSHPWMFanController {
        let endpoint = try XCTUnwrap(URL(string: "https://casaos.local"))
        let store = InMemorySSHCredentialStore()
        try await store.storeCasaOS(
            SSHCredentials(username: "admin", password: password),
            for: endpoint
        )
        return SSHPWMFanController(
            serverURL: endpoint,
            credentialMode: .casaOS,
            credentialStore: store,
            executor: executor
        )
    }

    private func result(
        output: String = "",
        error: String = "",
        exitStatus: Int = 0
    ) -> SSHCommandResult {
        SSHCommandResult(
            standardOutput: Data(output.utf8),
            standardError: Data(error.utf8),
            exitStatus: exitStatus
        )
    }

    private func decodedPrivilegedScript(
        _ request: SSHCommandRequest
    ) -> String {
        let marker = "/usr/bin/printf '%s' '"
        guard let start = request.command.range(of: marker)?.upperBound,
              let end = request.command[start...].firstIndex(of: "'"),
              let data = Data(base64Encoded: String(request.command[start..<end]))
        else {
            XCTFail("Missing encoded privileged script")
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func v3StableManualProbe(
        pin: PWMFanGPIOPin,
        duty: Int
    ) -> String {
        v3Probe([
            "managed_files": "exact",
            "disk_state": "managed_manual",
            "disk_pin": "\(pin.rawValue)",
            "disk_duty": "\(duty)",
            "live_state": "manual",
            "live_pin": "\(pin.rawValue)",
            "live_duty": "\(duty)",
            "live_period": "40000",
            "live_enabled": "1",
        ])
    }

    private func v3Probe(_ changes: [String: String] = [:]) -> String {
        var values: [String: String] = [
            "config": "1",
            "resource_conflict": "0",
            "unsupported_pwm_gpio": "0",
            "manual_capable": "1",
            "automatic_capable": "1",
            "managed_files": "none",
            "disk_state": "none",
            "disk_pin": "",
            "disk_duty": "",
            "disk_temp": "",
            "disk_hyst": "",
            "live_state": "none",
            "live_pin": "",
            "live_duty": "",
            "live_temp": "",
            "live_hyst": "",
            "live_period": "",
            "live_enabled": "",
            "automatic_demand": "",
            "transition": "none",
            "journal_phase": "",
            "recovery_action": "",
            "transition_kind": "",
            "transition_requirement": "",
            "source_state": "",
            "source_pin": "",
            "source_duty": "",
            "source_temp": "",
            "source_hyst": "",
            "target_state": "",
            "target_pin": "",
            "target_duty": "",
            "target_temp": "",
            "target_hyst": "",
            "legacy": "none",
            "recovery": "0",
            "pigs": "none",
            "pigs_path": "",
            "pigpio_version": "",
            "pigpio_pin": "",
            "pigpio_duty": "",
            "pigpio_frequency": "",
            "pigpio_mode": "",
        ]
        values.merge(changes) { _, new in new }
        let order = [
            "config", "resource_conflict", "unsupported_pwm_gpio",
            "manual_capable", "automatic_capable", "managed_files",
            "disk_state", "disk_pin", "disk_duty", "disk_temp", "disk_hyst",
            "live_state", "live_pin", "live_duty", "live_temp", "live_hyst",
            "live_period", "live_enabled", "automatic_demand",
            "transition", "journal_phase", "recovery_action",
            "transition_kind", "transition_requirement",
            "source_state", "source_pin", "source_duty", "source_temp", "source_hyst",
            "target_state", "target_pin", "target_duty", "target_temp", "target_hyst",
            "legacy", "recovery", "pigs", "pigs_path", "pigpio_version",
            "pigpio_pin", "pigpio_duty", "pigpio_frequency", "pigpio_mode",
        ]
        return "CASANATIVE_PWM_FAN_V3\n" + order.map {
            "\($0)\t\(values[$0]!)"
        }.joined(separator: "\n") + "\n"
    }

    private func probe(_ changes: [String: String] = [:]) -> String {
        var values: [String: String] = [
            "config": "1",
            "overlay": "",
            "legacy_block": "0",
            "legacy_script": "0",
            "legacy_service": "0",
            "managed_block": "0",
            "managed_helper": "0",
            "managed_defaults": "0",
            "managed_service": "0",
            "resource_conflict": "0",
            "gpio_fan_config": "0",
            "gpio_fan_config_pin": "",
            "gpio_fan_live": "0",
            "gpio_fan_live_pin": "",
            "pigs": "none",
            "pigs_path": "",
            "pigpio_version": "",
            "pigpio_pin": "",
            "pigpio_duty": "",
            "pigpio_frequency": "",
            "pigpio_mode": "",
            "sysfs_count": "0",
            "sysfs_pin": "",
            "sysfs_period": "",
            "sysfs_duty": "",
            "sysfs_enabled": "",
        ]
        values.merge(changes) { _, new in new }
        let order = [
            "config", "overlay", "legacy_block", "legacy_script", "legacy_service",
            "managed_block", "managed_helper", "managed_defaults", "managed_service",
            "resource_conflict",
            "gpio_fan_config", "gpio_fan_config_pin", "gpio_fan_live",
            "gpio_fan_live_pin", "pigs", "pigs_path", "pigpio_version",
            "pigpio_pin", "pigpio_duty", "pigpio_frequency", "pigpio_mode",
            "sysfs_count", "sysfs_pin", "sysfs_period", "sysfs_duty", "sysfs_enabled",
        ]
        return "CASANATIVE_PWM_FAN_V2\n" + order.map {
            "\($0)\t\(values[$0]!)"
        }.joined(separator: "\n") + "\n"
    }
}

private actor ScriptedPWMSSHExecutor: SSHCommandExecuting {
    private var remaining: [SSHCommandResult]
    private(set) var requests: [SSHCommandRequest] = []

    init(results: [SSHCommandResult]) {
        remaining = results
    }

    func execute(
        _ request: SSHCommandRequest,
        credentials: SSHCredentials
    ) async throws -> SSHCommandResult {
        requests.append(request)
        guard !remaining.isEmpty else {
            throw PWMFanError.invalidCommandResponse
        }
        return remaining.removeFirst()
    }
}
