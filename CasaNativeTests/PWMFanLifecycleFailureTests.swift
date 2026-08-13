import XCTest
@testable import CasaNative

/// Failure-injection coverage for the managed fan lifecycle state machine.
///
/// This suite deliberately does not execute the generated GNU/Linux shell on
/// macOS. It models the durable generations that those scripts publish, feeds
/// every modeled read-only snapshot through `PWMFanProbeParser`, and verifies
/// that retry converges. Separate assertions anchor each modeled cut point to
/// the production journal, block, helper, and mutation script output.
final class PWMFanLifecycleFailureTests: XCTestCase {
    private let bootA = "11111111-1111-1111-1111-111111111111"
    private let bootB = "22222222-2222-2222-2222-222222222222"

    func testGeneratedScriptsAnchorEveryModeledDurableCutpoint() throws {
        let source = manual(pin: .gpio18, duty: 50)
        let target = automatic(pin: .gpio18, temperature: 60, hysteresis: 10)
        let transition = PWMFanTransitionState(
            source: source,
            target: .configuration(target),
            phase: .prepared,
            requirement: .reboot,
            kind: .configurationChange
        )
        let prepare = PWMFanScripts.prepareConfigurationChange(
            source: source,
            target: target,
            requirement: .reboot,
            kind: .configurationChange
        )
        let cancel = PWMFanScripts.cancelPreparedChange(transition: transition)
        let booted = PWMFanTransitionState(
            source: source,
            target: .configuration(target),
            phase: .bootedAwaitingConfirmation,
            requirement: .reboot,
            kind: .configurationChange
        )
        let finalize = PWMFanScripts.finalizePreparedChange(transition: booted)
        let uninstall = PWMFanScripts.finalizePreparedChange(
            transition: PWMFanTransitionState(
                source: source,
                target: .uninstalled,
                phase: .bootedAwaitingConfirmation,
                requirement: .fullShutdown,
                kind: .uninstall
            )
        )
        let legacyConvert = PWMFanScripts.convertExactLegacyFan50()
        let legacyRestore = PWMFanScripts.resolveLegacyBackup(.restore)
        let legacyDiscard = PWMFanScripts.resolveLegacyBackup(.discard)

        XCTAssertTrue(prepare.contains("sync -f \"$temporary\""))
        XCTAssertTrue(
            prepare.contains("mv -f \"$temporary\" \"$STATE/journal\"")
        )
        XCTAssertTrue(prepare.contains("sync -f \"$STATE/journal\""))
        XCTAssertTrue(prepare.contains("sync -f \"$CFG_TMP\""))
        XCTAssertTrue(prepare.contains("mv \"$CFG_TMP\" \"$CFG\""))
        assertOrdered(
            [
                "write_journal '",
                "systemctl enable casanative-pwm-fan.service",
                "publish_replace \"$block_start\"",
                "sync -f \"$CFG\"",
                "sync -f \"${CFG%/*}\"",
                "sync -f \"$STATE\"",
            ],
            in: prepare
        )
        for script in [cancel, finalize, uninstall, legacyRestore, legacyDiscard] {
            XCTAssertTrue(script.contains("rewrite_journal_phase"))
            XCTAssertTrue(script.contains("2s/^PHASE=.*$/PHASE=$new_phase/"))
            XCTAssertFalse(
                script.contains("5s/^PREPARED_BOOT_ID=.*$/"),
                "Phase rewrites must preserve the original boot generation."
            )
        }
        XCTAssertTrue(cancel.contains("write_fixed"))
        XCTAssertTrue(finalize.contains("write_fixed"))
        XCTAssertTrue(uninstall.contains("rm -f \"$HELPER\""))
        XCTAssertTrue(uninstall.contains("rm -f \"$DEFAULT\""))
        XCTAssertTrue(uninstall.contains("rm -f \"$SERVICE\""))
        XCTAssertTrue(uninstall.contains("retire_state_atomically"))
        XCTAssertTrue(
            uninstall.contains("mv -T \"$STATE\" \"$STATE_REMOVAL\"")
        )
        XCTAssertTrue(uninstall.contains("sync -f /var/lib"))
        let cleanup = PWMFanScripts.completeStateCleanup()
        XCTAssertTrue(cleanup.contains("recover_retired_state"))
        XCTAssertTrue(cleanup.contains("rm -f \"$STATE_REMOVAL/journal\""))
        XCTAssertTrue(cleanup.contains("rmdir \"$STATE_REMOVAL\""))

        for backup in ["legacy-helper", "legacy-service", "legacy-meta"] {
            XCTAssertTrue(legacyConvert.contains("$STATE/\(backup)"))
            XCTAssertTrue(legacyRestore.contains(backup))
            XCTAssertTrue(legacyDiscard.contains(backup))
        }
        XCTAssertTrue(legacyConvert.contains("copy_backup"))
        XCTAssertTrue(legacyRestore.contains("ensure_backup_copy"))
        XCTAssertTrue(legacyRestore.contains("rm -f \"$path\""))
        XCTAssertTrue(legacyDiscard.contains("rm -f \"$path\""))

        let journal = PWMFanManagedLifecycleScripts.journal(
            source: source,
            target: .configuration(target),
            kind: .configurationChange,
            requirement: .reboot,
            bootIDExpression: "TEST_BOOT"
        )
        XCTAssertEqual(journal.split(separator: "\n").count, 17)
        XCTAssertTrue(journal.contains("PHASE=prepared"))
        XCTAssertTrue(journal.contains("PREPARED_BOOT_ID=TEST_BOOT"))
        XCTAssertTrue(journal.contains("SOURCE_MODE=manual"))
        XCTAssertTrue(journal.contains("TARGET_MODE=automatic"))
        XCTAssertTrue(journal.contains("TARGET_TEMP=60"))
        XCTAssertTrue(journal.contains("TARGET_HYST=10"))
        XCTAssertEqual(
            PWMFanManagedLifecycleScripts.block(for: target),
            "# BEGIN CasaNative GPIO Fan\n"
                + "dtoverlay=gpio-fan,gpiopin=18,temp=60000,hyst=10000\n"
                + "# END CasaNative GPIO Fan"
        )
    }

    func testPrepareCutpointsFailClosedOrExposePendingAndRetryConverges() throws {
        let source = manual(pin: .gpio18, duty: 50)
        let target = automatic(pin: .gpio18, temperature: 60, hysteresis: 10)

        for cutpoint in PrepareCutpoint.allCases {
            var fixture = Fixture.preparing(
                source: source,
                target: target,
                cutpoint: cutpoint,
                bootID: bootA
            )
            let status = try fixture.status()
            XCTAssertLessThanOrEqual(
                fixture.recoveryActions.count,
                1,
                "\(cutpoint) exposed more than one recovery action"
            )

            switch cutpoint {
            case .beforeJournal:
                assertStable(status, configuration: source)
            case .journalTemporarySynced:
                assertRecovery(status, action: nil)
            case .journalPublished, .serviceUpdated, .configTemporarySynced:
                assertRecovery(status, action: .cancelPreparedChange)
            case .configPublished, .configParentSynced:
                XCTAssertFalse(status.recoveryRequired)
                XCTAssertEqual(status.transition?.phase, .prepared)
                XCTAssertEqual(status.activeConfiguration, source)
                XCTAssertEqual(status.pendingConfiguration, target)
            }

            fixture.retryOriginalOperation()
            let retried = try fixture.status()
            if cutpoint == .beforeJournal {
                assertStable(retried, configuration: source)
            } else if cutpoint == .journalPublished
                        || cutpoint == .serviceUpdated
                        || cutpoint == .configTemporarySynced {
                assertStable(retried, configuration: source)
            } else {
                XCTAssertFalse(retried.recoveryRequired)
                XCTAssertEqual(retried.transition?.phase, .prepared)
                XCTAssertEqual(retried.activeConfiguration, source)
                XCTAssertEqual(retried.pendingConfiguration, target)
            }
        }
    }

    func testFreshProvisionStateStageIsNotFalseCleanAndCancelRetryConverges() throws {
        let target = manual(pin: .gpio12, duty: 50)
        var fixture = Fixture.stagedFreshProvision(
            target: target,
            bootID: bootA
        )

        let interrupted = try fixture.status()
        assertRecovery(interrupted, action: .cancelPreparedChange)
        XCTAssertEqual(fixture.recoveryActions, [.cancelPreparedChange])
        XCTAssertNil(interrupted.activeConfiguration)
        XCTAssertEqual(interrupted.pendingConfiguration, target)

        fixture.retryOriginalOperation()
        let retried = try fixture.status()
        XCTAssertEqual(retried.ownership, .absent)
        XCTAssertFalse(retried.recoveryRequired)

        let detection = PWMFanManagedLifecycleScripts.detectionShell
        let provision = PWMFanScripts.provision(
            configuration: target,
            requirement: .reboot
        )
        let transition = PWMFanTransitionState(
            source: nil,
            target: .configuration(target),
            phase: .prepared,
            requirement: .reboot,
            kind: .configurationChange
        )
        let cancel = PWMFanScripts.cancelPreparedChange(transition: transition)
        XCTAssertTrue(detection.contains("STATE_STAGE=/var/lib/.casanative-pwm-fan.new"))
        XCTAssertTrue(detection.contains("stage_recovery=1"))
        XCTAssertTrue(provision.contains("create_state_with_journal"))
        XCTAssertTrue(cancel.contains("adopt_staged_state"))
    }

    func testSameBootUsesSourceAndNewBootUsesTargetUntilConfirmation() throws {
        let source = automatic(pin: .gpio18, temperature: 55, hysteresis: 10)
        let target = automatic(pin: .gpio18, temperature: 60, hysteresis: 10)
        var fixture = Fixture.preparing(
            source: source,
            target: target,
            cutpoint: .configParentSynced,
            bootID: bootA
        )

        let sameBoot = try fixture.status()
        XCTAssertEqual(sameBoot.transition?.phase, .prepared)
        XCTAssertEqual(sameBoot.activeConfiguration, source)
        XCTAssertEqual(sameBoot.pendingConfiguration, target)

        fixture.boot(into: bootB)
        let newBoot = try fixture.status()
        XCTAssertEqual(
            newBoot.transition?.phase,
            .bootedAwaitingConfirmation
        )
        XCTAssertEqual(newBoot.activeConfiguration, target)
        XCTAssertEqual(newBoot.pendingConfiguration, target)

        let helper = PWMFanManagedLifecycleScripts.helper
        XCTAssertTrue(
            helper.contains(
                "[ \"$config_record\" = \"$source_mode|$source_pin\" ]"
            )
        )
        XCTAssertTrue(
            helper.contains(
                "[ \"$config_record\" = \"$target_mode|$target_pin\" ] && [ \"$current\" != \"$prepared\" ]"
            )
        )
    }

    func testInterruptedRollbackPreparationCompletesToPreparedRollback() throws {
        let source = automatic(pin: .gpio18, temperature: 60, hysteresis: 10)
        let target = automatic(pin: .gpio18, temperature: 55, hysteresis: 10)
        var fixture = Fixture.preparing(
            source: source,
            target: target,
            cutpoint: .journalPublished,
            bootID: bootA
        )
        fixture.journal?.kind = .rollback

        let interrupted = try fixture.status()
        assertRecovery(interrupted, action: .completeRollbackPreparation)
        XCTAssertEqual(fixture.recoveryActions, [.completeRollbackPreparation])
        XCTAssertNil(interrupted.activeConfiguration)
        XCTAssertEqual(interrupted.transition?.source, source)
        XCTAssertEqual(interrupted.pendingConfiguration, target)

        fixture.retryOriginalOperation()
        let retried = try fixture.status()
        XCTAssertFalse(retried.recoveryRequired)
        XCTAssertEqual(retried.transition?.phase, .prepared)
        XCTAssertEqual(retried.transition?.kind, .rollback)
        XCTAssertEqual(retried.activeConfiguration, source)
        XCTAssertEqual(retried.pendingConfiguration, target)
    }

    func testBootedUninstallReverseRollbackCutpointsRestoreAndFinalize() throws {
        let original = automatic(
            pin: .gpio18,
            temperature: 55,
            hysteresis: 10
        )

        for cutpoint in RollbackPrepareCutpoint.allCases {
            var fixture = Fixture.preparingRollback(
                source: nil,
                target: .configuration(original),
                cutpoint: cutpoint,
                bootID: bootA
            )
            let interrupted = try fixture.status()
            if cutpoint.requiresCompletionRecovery {
                assertRecovery(
                    interrupted,
                    action: .completeRollbackPreparation
                )
                XCTAssertEqual(
                    fixture.recoveryActions,
                    [.completeRollbackPreparation]
                )
            } else {
                XCTAssertFalse(interrupted.recoveryRequired)
                XCTAssertTrue(fixture.recoveryActions.isEmpty)
            }

            fixture.retryOriginalOperation()
            let prepared = try fixture.status()
            XCTAssertFalse(prepared.recoveryRequired)
            XCTAssertEqual(prepared.transition?.phase, .prepared)
            XCTAssertEqual(prepared.transition?.kind, .rollback)
            XCTAssertNil(prepared.activeConfiguration)
            XCTAssertEqual(prepared.pendingConfiguration, original)

            fixture.boot(into: bootB)
            let booted = try fixture.status()
            XCTAssertEqual(
                booted.transition?.phase,
                .bootedAwaitingConfirmation
            )
            XCTAssertEqual(booted.activeConfiguration, original)

            fixture.beginFinalization()
            let finalizing = try fixture.status()
            assertRecovery(finalizing, action: .finalizePreparedChange)
            XCTAssertEqual(fixture.recoveryActions, [.finalizePreparedChange])
            fixture.retryOriginalOperation()
            assertStable(try fixture.status(), configuration: original)
        }
    }

    func testBootedFreshProvisionReverseRollbackCutpointsRemoveAndFinalize() throws {
        let provisioned = automatic(
            pin: .gpio18,
            temperature: 55,
            hysteresis: 10
        )

        for cutpoint in RollbackPrepareCutpoint.allCases {
            var fixture = Fixture.preparingRollback(
                source: provisioned,
                target: .uninstalled,
                cutpoint: cutpoint,
                bootID: bootA
            )
            let interrupted = try fixture.status()
            if cutpoint.requiresCompletionRecovery {
                assertRecovery(
                    interrupted,
                    action: .completeRollbackPreparation
                )
                XCTAssertEqual(
                    fixture.recoveryActions,
                    [.completeRollbackPreparation]
                )
            } else {
                XCTAssertFalse(interrupted.recoveryRequired)
                XCTAssertTrue(fixture.recoveryActions.isEmpty)
            }

            fixture.retryOriginalOperation()
            let prepared = try fixture.status()
            XCTAssertFalse(prepared.recoveryRequired)
            XCTAssertEqual(prepared.transition?.phase, .prepared)
            XCTAssertEqual(prepared.transition?.kind, .rollback)
            XCTAssertEqual(prepared.activeConfiguration, provisioned)
            XCTAssertNil(prepared.pendingConfiguration)
            XCTAssertEqual(prepared.transition?.isPendingUninstall, true)

            fixture.boot(into: bootB)
            let booted = try fixture.status()
            XCTAssertEqual(
                booted.transition?.phase,
                .bootedAwaitingConfirmation
            )
            XCTAssertNil(booted.activeConfiguration)
            XCTAssertEqual(booted.transition?.isPendingUninstall, true)

            fixture.beginFinalization()
            let finalizing = try fixture.status()
            assertRecovery(finalizing, action: .finalizePreparedChange)
            XCTAssertEqual(fixture.recoveryActions, [.finalizePreparedChange])
            fixture.retryOriginalOperation()
            let finalized = try fixture.status()
            XCTAssertEqual(finalized.ownership, .absent)
            XCTAssertNil(finalized.transition)
            XCTAssertFalse(finalized.recoveryRequired)
        }
    }

    func testCancelCutpointsExposeOneActionUntilSourceIsStable() throws {
        let source = manual(pin: .gpio18, duty: 50)
        let target = automatic(pin: .gpio18, temperature: 55, hysteresis: 10)

        for cutpoint in CancelCutpoint.allCases {
            var fixture = Fixture.cancelling(
                source: source,
                target: target,
                cutpoint: cutpoint,
                bootID: bootA
            )
            let status = try fixture.status()
            if cutpoint == .journalDeleted {
                assertStable(status, configuration: source)
            } else {
                assertRecovery(status, action: .cancelPreparedChange)
                XCTAssertEqual(fixture.recoveryActions.count, 1)
            }

            fixture.retryOriginalOperation()
            assertStable(try fixture.status(), configuration: source)
        }
    }

    func testFinalizeCutpointsExposeOneActionUntilTargetIsStable() throws {
        let source = manual(pin: .gpio18, duty: 50)
        let target = automatic(pin: .gpio18, temperature: 55, hysteresis: 10)

        for cutpoint in FinalizeCutpoint.allCases {
            var fixture = Fixture.finalizing(
                source: source,
                target: target,
                cutpoint: cutpoint,
                preparedBootID: bootA,
                currentBootID: bootB
            )
            let status = try fixture.status()
            if cutpoint == .journalDeleted {
                assertStable(status, configuration: target)
            } else {
                assertRecovery(status, action: .finalizePreparedChange)
                XCTAssertEqual(fixture.recoveryActions.count, 1)
            }

            fixture.retryOriginalOperation()
            assertStable(try fixture.status(), configuration: target)
        }
    }

    func testUninstallAssetAndDirectoryCutpointsNeverLookClean() throws {
        let source = manual(pin: .gpio19, duty: 45)

        for cutpoint in UninstallCutpoint.allCases {
            var fixture = Fixture.uninstalling(
                source: source,
                cutpoint: cutpoint,
                preparedBootID: bootA,
                currentBootID: bootB
            )
            let status = try fixture.status()
            if cutpoint == .tombstoneRemoved {
                XCTAssertEqual(status.ownership, .absent)
                XCTAssertFalse(status.recoveryRequired)
            } else if cutpoint.isBeforeRetirement {
                assertRecovery(status, action: .completeUninstall)
                XCTAssertEqual(fixture.recoveryActions.count, 1)
            } else {
                assertRecovery(status, action: .completeStateCleanup)
                XCTAssertEqual(fixture.recoveryActions, [.completeStateCleanup])
            }

            fixture.retryOriginalOperation()
            let retried = try fixture.status()
            XCTAssertEqual(retried.ownership, .absent)
            XCTAssertFalse(retried.recoveryRequired)
        }
    }

    func testAtomicRemovalTombstoneExactSubsetsExposeOnlyCleanupAndConverge() throws {
        let subsets: [Set<RemovalEntry>] = [
            [.journal, .lock],
            [.journal],
            [.lock],
            [],
        ]
        for contents in subsets {
            var fixture = Fixture.removalTombstone(
                contents: contents,
                integrity: .exact,
                bootID: bootA
            )
            let status = try fixture.status()
            assertRecovery(status, action: .completeStateCleanup)
            XCTAssertNil(status.transition)
            XCTAssertEqual(fixture.recoveryActions, [.completeStateCleanup])

            fixture.retryOriginalOperation()
            let retried = try fixture.status()
            XCTAssertEqual(retried.ownership, .absent)
            XCTAssertFalse(retried.recoveryRequired)
        }
    }

    func testAtomicRemovalTombstoneMalformedEntriesAreRejectedWithoutCleanup() {
        for integrity in RemovalIntegrity.unsafeCases {
            let fixture = Fixture.removalTombstone(
                contents: [.journal, .lock],
                integrity: integrity,
                bootID: bootA
            )
            XCTAssertThrowsError(try fixture.status()) { error in
                XCTAssertEqual(error as? HarnessDetectionError, .unsafeTombstone)
            }
            XCTAssertTrue(fixture.recoveryActions.isEmpty)
        }

        let detection = PWMFanManagedLifecycleScripts.detectionShell
        XCTAssertTrue(detection.contains("STATE_REMOVAL=/var/lib/.casanative-pwm-fan.removing"))
        XCTAssertTrue(detection.contains("[ -d \"$STATE_REMOVAL\" ] && [ ! -L \"$STATE_REMOVAL\" ]"))
        XCTAssertTrue(detection.contains("case \"${item##*/}\" in lock|journal"))
        XCTAssertTrue(detection.contains("regular_root_file \"$STATE_REMOVAL/lock\" '0:600:1'"))
        XCTAssertTrue(detection.contains("canonical_journal_shape \"$STATE_REMOVAL/journal\""))
        XCTAssertTrue(detection.contains("recovery_action=completeStateCleanup"))
        let cleanup = PWMFanScripts.completeStateCleanup()
        XCTAssertTrue(cleanup.contains("recover_retired_state"))
        XCTAssertFalse(cleanup.contains("rm -rf"))
    }

    func testLegacyConversionCutpointsConvergeToManagedBackupResolution() throws {
        let managed = manual(pin: .gpio18, duty: 50)

        for cutpoint in LegacyConversionCutpoint.allCases {
            var fixture = Fixture.convertingLegacy(
                managed: managed,
                cutpoint: cutpoint,
                bootID: bootA
            )
            let status = try fixture.status()
            if cutpoint == .journalDeleted {
                assertStable(status, configuration: managed)
                XCTAssertEqual(
                    status.legacyState,
                    .backupAwaitingResolution
                )
            } else {
                assertRecovery(status, action: .completeLegacyConversion)
                XCTAssertEqual(fixture.recoveryActions.count, 1)
            }

            fixture.retryOriginalOperation()
            let retried = try fixture.status()
            assertStable(retried, configuration: managed)
            XCTAssertEqual(retried.legacyState, .backupAwaitingResolution)
        }
    }

    func testLegacyRestoreAndDiscardDeleteEveryBackupIdempotently() throws {
        let managed = manual(pin: .gpio18, duty: 50)

        for cutpoint in LegacyRestoreCutpoint.allCases {
            var fixture = Fixture.restoringLegacy(
                managed: managed,
                cutpoint: cutpoint,
                bootID: bootA
            )
            let status = try fixture.status()
            if cutpoint == .tombstoneRemoved {
                XCTAssertEqual(status.ownership, .external)
                XCTAssertEqual(status.legacyState, .exactConvertible)
            } else if cutpoint.isBeforeRetirement {
                assertRecovery(status, action: .completeLegacyRestore)
            } else {
                assertRecovery(status, action: .completeStateCleanup)
            }
            fixture.retryOriginalOperation()
            let retried = try fixture.status()
            XCTAssertEqual(retried.ownership, .external)
            XCTAssertEqual(retried.legacyState, .exactConvertible)
        }

        for cutpoint in LegacyDiscardCutpoint.allCases {
            var fixture = Fixture.discardingLegacy(
                managed: managed,
                cutpoint: cutpoint,
                bootID: bootA
            )
            let status = try fixture.status()
            if cutpoint == .journalDeleted {
                assertStable(status, configuration: managed)
                XCTAssertEqual(status.legacyState, .none)
            } else {
                assertRecovery(status, action: .completeLegacyDiscard)
            }
            fixture.retryOriginalOperation()
            let retried = try fixture.status()
            assertStable(retried, configuration: managed)
            XCTAssertEqual(retried.legacyState, .none)
        }
    }

    func testDanglingSymlinkAndSpecialFileFixturesFailClosed() throws {
        let configuration = manual(pin: .gpio18, duty: 50)
        for corruption in [Integrity.danglingSymlink, .specialFile] {
            let fixture = Fixture.corruptStable(
                configuration: configuration,
                integrity: corruption,
                bootID: bootA
            )
            let status = try fixture.status()
            assertRecovery(status, action: nil)
            XCTAssertNotEqual(status.ownership, .managed)
        }
    }

    func testAutomaticTopologyUsesThermalZoneCdevSymlinkAndTripPoint() throws {
        let automatic = automatic(
            pin: .gpio12,
            temperature: 55,
            hysteresis: 10
        )
        let valid = Fixture.stable(
            configuration: automatic,
            bootID: bootA,
            topology: AutomaticTopology(
                thermalZoneCdevSymlink: true,
                cdevTripPoint: true,
                coolingDeviceParentLink: false
            )
        )
        let validStatus = try valid.status()
        assertStable(validStatus, configuration: automatic)
        XCTAssertEqual(validStatus.automaticDemand, .off)

        for invalid in [
            AutomaticTopology(
                thermalZoneCdevSymlink: false,
                cdevTripPoint: true,
                coolingDeviceParentLink: false
            ),
            AutomaticTopology(
                thermalZoneCdevSymlink: true,
                cdevTripPoint: false,
                coolingDeviceParentLink: false
            ),
        ] {
            let fixture = Fixture.stable(
                configuration: automatic,
                bootID: bootA,
                topology: invalid
            )
            let status = try fixture.status()
            XCTAssertEqual(status.ownership, .conflict)
            XCTAssertFalse(status.isRuntimeAvailable)
        }

        let detection = PWMFanManagedLifecycleScripts.detectionShell
        XCTAssertTrue(detection.contains("thermal_zone*"))
        XCTAssertTrue(detection.contains("/cdev*"))
        XCTAssertTrue(detection.contains("cdev${index}_trip_point"))
        XCTAssertFalse(detection.contains("$cooling/device"))
    }

    private func manual(
        pin: PWMFanGPIOPin,
        duty: Int
    ) -> PWMFanConfiguration {
        .manual(try! PWMFanManualConfiguration(pin: pin, dutyPercent: duty))
    }

    private func automatic(
        pin: PWMFanGPIOPin,
        temperature: Int,
        hysteresis: Int
    ) -> PWMFanConfiguration {
        .automatic(
            try! PWMFanAutomaticConfiguration(
                pin: pin,
                turnOnCelsius: temperature,
                hysteresisCelsius: hysteresis
            )
        )
    }

    private func assertStable(
        _ status: PWMFanStatus,
        configuration: PWMFanConfiguration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(status.ownership, .managed, file: file, line: line)
        XCTAssertEqual(
            status.activeConfiguration,
            configuration,
            file: file,
            line: line
        )
        XCTAssertNil(status.transition, file: file, line: line)
        XCTAssertFalse(status.recoveryRequired, file: file, line: line)
        XCTAssertNil(status.recoveryAction, file: file, line: line)
    }

    private func assertRecovery(
        _ status: PWMFanStatus,
        action: PWMFanRecoveryAction?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(status.ownership, .conflict, file: file, line: line)
        XCTAssertTrue(status.recoveryRequired, file: file, line: line)
        XCTAssertEqual(status.recoveryAction, action, file: file, line: line)
    }

    private func assertOrdered(
        _ needles: [String],
        in haystack: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lowerBound = haystack.startIndex
        for needle in needles {
            guard let range = haystack.range(
                of: needle,
                range: lowerBound..<haystack.endIndex
            ) else {
                XCTFail("Missing ordered script fragment: \(needle)", file: file, line: line)
                return
            }
            lowerBound = range.upperBound
        }
    }
}

private enum PrepareCutpoint: CaseIterable, Equatable {
    case beforeJournal
    case journalTemporarySynced
    case journalPublished
    case serviceUpdated
    case configTemporarySynced
    case configPublished
    case configParentSynced
}

private enum CancelCutpoint: CaseIterable, Equatable {
    case phasePublished
    case defaultsPublished
    case serviceUpdated
    case configTemporarySynced
    case configPublished
    case configParentSynced
    case journalDeleted
}

private enum RollbackPrepareCutpoint: CaseIterable, Equatable {
    case journalPublished
    case serviceUpdated
    case configPublished

    var requiresCompletionRecovery: Bool {
        self != .configPublished
    }
}

private enum FinalizeCutpoint: CaseIterable, Equatable {
    case phasePublished
    case defaultsPublished
    case serviceUpdated
    case journalDeleted
}

private enum UninstallCutpoint: CaseIterable, Equatable {
    case phasePublished
    case helperDeleted
    case defaultsDeleted
    case serviceDeleted
    case stateRetired
    case tombstoneJournalOnly
    case tombstoneLockOnly
    case tombstoneEmpty
    case tombstoneRemoved

    var isBeforeRetirement: Bool {
        switch self {
        case .phasePublished, .helperDeleted, .defaultsDeleted, .serviceDeleted:
            true
        case .stateRetired, .tombstoneJournalOnly, .tombstoneLockOnly,
             .tombstoneEmpty, .tombstoneRemoved:
            false
        }
    }
}

private enum LegacyConversionCutpoint: CaseIterable, Equatable {
    case journalPublished
    case helperBackupPublished
    case serviceBackupPublished
    case metadataBackupPublished
    case managedHelperPublished
    case managedDefaultsPublished
    case managedServicePublished
    case configPublished
    case legacyHelperDeleted
    case legacyServiceDeleted
    case journalDeleted
}

private enum LegacyRestoreCutpoint: CaseIterable, Equatable {
    case phasePublished
    case legacyHelperPublished
    case legacyServicePublished
    case configPublished
    case managedHelperDeleted
    case managedDefaultsDeleted
    case managedServiceDeleted
    case helperBackupDeleted
    case serviceBackupDeleted
    case metadataBackupDeleted
    case stateRetired
    case tombstoneJournalOnly
    case tombstoneLockOnly
    case tombstoneEmpty
    case tombstoneRemoved

    var isBeforeRetirement: Bool {
        switch self {
        case .phasePublished, .legacyHelperPublished, .legacyServicePublished,
             .configPublished, .managedHelperDeleted, .managedDefaultsDeleted,
             .managedServiceDeleted, .helperBackupDeleted,
             .serviceBackupDeleted, .metadataBackupDeleted:
            true
        case .stateRetired, .tombstoneJournalOnly, .tombstoneLockOnly,
             .tombstoneEmpty, .tombstoneRemoved:
            false
        }
    }
}

private enum LegacyDiscardCutpoint: CaseIterable, Equatable {
    case phasePublished
    case helperBackupDeleted
    case serviceBackupDeleted
    case metadataBackupDeleted
    case journalDeleted
}

private enum Integrity: Equatable {
    case exact
    case journalTemporary
    case configTemporary
    case danglingSymlink
    case specialFile
}

private enum RemovalEntry: Hashable {
    case journal
    case lock
}

private enum RemovalIntegrity: Equatable {
    case exact
    case danglingSymlink
    case specialFile
    case extraEntry
    case wrongOwner

    static let unsafeCases: [RemovalIntegrity] = [
        .danglingSymlink,
        .specialFile,
        .extraEntry,
        .wrongOwner,
    ]
}

private struct RemovalTombstone: Equatable {
    var contents: Set<RemovalEntry>
    var integrity: RemovalIntegrity
}

private enum HarnessDetectionError: Error, Equatable {
    case unsafeTombstone
}

private struct AutomaticTopology: Equatable {
    var thermalZoneCdevSymlink = true
    var cdevTripPoint = true
    // The kernel ABI does not require a cooling_deviceN/device parent link.
    var coolingDeviceParentLink = false

    var isValid: Bool {
        thermalZoneCdevSymlink && cdevTripPoint
    }
}

private enum BootBlock: Equatable {
    case none
    case managed(PWMFanConfiguration)
    case exactLegacy

    var configuration: PWMFanConfiguration? {
        switch self {
        case let .managed(value): value
        case .exactLegacy:
            .manual(.defaultConfiguration(pin: .gpio18))
        case .none: nil
        }
    }
}

private enum DurableJournalPhase: String {
    case prepared
    case cancelling
    case finalizing
    case legacyConverting
    case legacyRestoring
    case legacyDiscarding
}

private struct DurableJournal {
    var source: PWMFanConfiguration?
    var target: PWMFanTransitionTarget
    var kind: PWMFanTransitionKind
    var requirement: PWMFanTransitionRequirement
    var preparedBootID: String
    var phase: DurableJournalPhase
}

private struct Fixture {
    var currentBootID: String
    var bootBlock: BootBlock
    var liveConfiguration: PWMFanConfiguration?
    var defaults: PWMFanConfiguration?
    var journal: DurableJournal?
    var intendedSource: PWMFanConfiguration?
    var intendedTarget: PWMFanTransitionTarget?
    var integrity = Integrity.exact
    var stateDirectory = true
    var stagedState = false
    var removalTombstone: RemovalTombstone?
    var lock = true
    var helper = true
    var defaultFile = true
    var service = true
    var legacyBackups: Set<String> = []
    var legacyHelper = false
    var legacyService = false
    var automaticTopology = AutomaticTopology()

    static func stable(
        configuration: PWMFanConfiguration,
        bootID: String,
        topology: AutomaticTopology = AutomaticTopology()
    ) -> Fixture {
        Fixture(
            currentBootID: bootID,
            bootBlock: .managed(configuration),
            liveConfiguration: configuration,
            defaults: configuration,
            journal: nil,
            intendedSource: configuration,
            intendedTarget: .configuration(configuration),
            automaticTopology: topology
        )
    }

    static func corruptStable(
        configuration: PWMFanConfiguration,
        integrity: Integrity,
        bootID: String
    ) -> Fixture {
        var result = stable(configuration: configuration, bootID: bootID)
        result.integrity = integrity
        return result
    }

    static func stagedFreshProvision(
        target: PWMFanConfiguration,
        bootID: String
    ) -> Fixture {
        Fixture(
            currentBootID: bootID,
            bootBlock: .none,
            liveConfiguration: nil,
            defaults: nil,
            journal: DurableJournal(
                source: nil,
                target: .configuration(target),
                kind: .configurationChange,
                requirement: .reboot,
                preparedBootID: bootID,
                phase: .prepared
            ),
            intendedSource: nil,
            intendedTarget: .configuration(target),
            stagedState: true,
            helper: false,
            defaultFile: false,
            service: false
        )
    }

    static func removalTombstone(
        contents: Set<RemovalEntry>,
        integrity: RemovalIntegrity,
        bootID: String
    ) -> Fixture {
        Fixture(
            currentBootID: bootID,
            bootBlock: .none,
            liveConfiguration: nil,
            defaults: nil,
            journal: nil,
            intendedSource: nil,
            intendedTarget: .uninstalled,
            stateDirectory: false,
            removalTombstone: RemovalTombstone(
                contents: contents,
                integrity: integrity
            ),
            lock: false,
            helper: false,
            defaultFile: false,
            service: false
        )
    }

    static func preparing(
        source: PWMFanConfiguration,
        target: PWMFanConfiguration,
        cutpoint: PrepareCutpoint,
        bootID: String
    ) -> Fixture {
        var result = stable(configuration: source, bootID: bootID)
        result.intendedTarget = .configuration(target)
        guard cutpoint != .beforeJournal else { return result }
        if cutpoint == .journalTemporarySynced {
            result.integrity = .journalTemporary
            return result
        }
        result.journal = DurableJournal(
            source: source,
            target: .configuration(target),
            kind: .configurationChange,
            requirement: source.pin == target.pin ? .reboot : .fullShutdown,
            preparedBootID: bootID,
            phase: .prepared
        )
        if cutpoint == .configTemporarySynced {
            result.integrity = .configTemporary
        }
        if cutpoint == .configPublished || cutpoint == .configParentSynced {
            result.bootBlock = .managed(target)
        }
        return result
    }

    static func cancelling(
        source: PWMFanConfiguration,
        target: PWMFanConfiguration,
        cutpoint: CancelCutpoint,
        bootID: String
    ) -> Fixture {
        var result = preparing(
            source: source,
            target: target,
            cutpoint: .configParentSynced,
            bootID: bootID
        )
        result.journal?.phase = .cancelling
        if cutpoint != .phasePublished {
            result.defaults = source
        }
        if cutpoint == .configTemporarySynced {
            result.integrity = .configTemporary
        }
        if cutpoint == .configPublished
            || cutpoint == .configParentSynced
            || cutpoint == .journalDeleted {
            result.bootBlock = .managed(source)
        }
        if cutpoint == .journalDeleted {
            result.journal = nil
        }
        return result
    }

    static func preparingRollback(
        source: PWMFanConfiguration?,
        target: PWMFanTransitionTarget,
        cutpoint: RollbackPrepareCutpoint,
        bootID: String
    ) -> Fixture {
        let sourceBlock = source.map(BootBlock.managed) ?? .none
        let targetBlock = target.configuration.map(BootBlock.managed) ?? .none
        let requirement: PWMFanTransitionRequirement
        if source == nil || target.isUninstall {
            requirement = .fullShutdown
        } else {
            requirement = source?.pin == target.configuration?.pin
                ? .reboot : .fullShutdown
        }
        var result = Fixture(
            currentBootID: bootID,
            bootBlock: sourceBlock,
            liveConfiguration: source,
            defaults: target.configuration ?? source,
            journal: DurableJournal(
                source: source,
                target: target,
                kind: .rollback,
                requirement: requirement,
                preparedBootID: bootID,
                phase: .prepared
            ),
            intendedSource: source,
            intendedTarget: target
        )
        if cutpoint == .configPublished {
            result.bootBlock = targetBlock
        }
        return result
    }

    static func finalizing(
        source: PWMFanConfiguration,
        target: PWMFanConfiguration,
        cutpoint: FinalizeCutpoint,
        preparedBootID: String,
        currentBootID: String
    ) -> Fixture {
        var result = stable(configuration: target, bootID: currentBootID)
        result.defaults = source
        // Once finalize has deleted its journal, repeating finalize must keep
        // the already-confirmed target rather than resurrecting the source.
        result.intendedSource = target
        result.intendedTarget = .configuration(target)
        result.journal = DurableJournal(
            source: source,
            target: .configuration(target),
            kind: .configurationChange,
            requirement: source.pin == target.pin ? .reboot : .fullShutdown,
            preparedBootID: preparedBootID,
            phase: .finalizing
        )
        if cutpoint != .phasePublished {
            result.defaults = target
        }
        if cutpoint == .journalDeleted {
            result.journal = nil
        }
        return result
    }

    static func uninstalling(
        source: PWMFanConfiguration,
        cutpoint: UninstallCutpoint,
        preparedBootID: String,
        currentBootID: String
    ) -> Fixture {
        var result = stable(configuration: source, bootID: currentBootID)
        result.bootBlock = .none
        result.liveConfiguration = nil
        result.intendedSource = source
        result.intendedTarget = .uninstalled
        result.journal = DurableJournal(
            source: source,
            target: .uninstalled,
            kind: .uninstall,
            requirement: .fullShutdown,
            preparedBootID: preparedBootID,
            phase: .finalizing
        )
        if cutpoint.rawOrder >= UninstallCutpoint.helperDeleted.rawOrder {
            result.helper = false
        }
        if cutpoint.rawOrder >= UninstallCutpoint.defaultsDeleted.rawOrder {
            result.defaultFile = false
            result.defaults = nil
        }
        if cutpoint.rawOrder >= UninstallCutpoint.serviceDeleted.rawOrder {
            result.service = false
        }
        if cutpoint.rawOrder >= UninstallCutpoint.stateRetired.rawOrder {
            result.stateDirectory = false
            result.lock = false
            result.journal = nil
            result.removalTombstone = RemovalTombstone(
                contents: [.journal, .lock],
                integrity: .exact
            )
        }
        if cutpoint == .tombstoneJournalOnly {
            result.removalTombstone?.contents = [.journal]
        }
        if cutpoint == .tombstoneLockOnly {
            result.removalTombstone?.contents = [.lock]
        }
        if cutpoint == .tombstoneEmpty {
            result.removalTombstone?.contents = []
        }
        if cutpoint == .tombstoneRemoved {
            result.removalTombstone = nil
        }
        return result
    }

    static func convertingLegacy(
        managed: PWMFanConfiguration,
        cutpoint: LegacyConversionCutpoint,
        bootID: String
    ) -> Fixture {
        var result = Fixture(
            currentBootID: bootID,
            bootBlock: .exactLegacy,
            liveConfiguration: managed,
            defaults: nil,
            journal: DurableJournal(
                source: nil,
                target: .configuration(managed),
                kind: .configurationChange,
                requirement: .reboot,
                preparedBootID: bootID,
                phase: .legacyConverting
            ),
            intendedSource: nil,
            intendedTarget: .configuration(managed),
            helper: false,
            defaultFile: false,
            service: false,
            legacyHelper: true,
            legacyService: true
        )
        if cutpoint.rawOrder >= LegacyConversionCutpoint.helperBackupPublished.rawOrder {
            result.legacyBackups.insert("legacy-helper")
        }
        if cutpoint.rawOrder >= LegacyConversionCutpoint.serviceBackupPublished.rawOrder {
            result.legacyBackups.insert("legacy-service")
        }
        if cutpoint.rawOrder >= LegacyConversionCutpoint.metadataBackupPublished.rawOrder {
            result.legacyBackups.insert("legacy-meta")
        }
        if cutpoint.rawOrder >= LegacyConversionCutpoint.managedHelperPublished.rawOrder {
            result.helper = true
        }
        if cutpoint.rawOrder >= LegacyConversionCutpoint.managedDefaultsPublished.rawOrder {
            result.defaultFile = true
            result.defaults = managed
        }
        if cutpoint.rawOrder >= LegacyConversionCutpoint.managedServicePublished.rawOrder {
            result.service = true
        }
        if cutpoint.rawOrder >= LegacyConversionCutpoint.configPublished.rawOrder {
            result.bootBlock = .managed(managed)
        }
        if cutpoint.rawOrder >= LegacyConversionCutpoint.legacyHelperDeleted.rawOrder {
            result.legacyHelper = false
        }
        if cutpoint.rawOrder >= LegacyConversionCutpoint.legacyServiceDeleted.rawOrder {
            result.legacyService = false
        }
        if cutpoint == .journalDeleted {
            result.journal = nil
        }
        return result
    }

    static func restoringLegacy(
        managed: PWMFanConfiguration,
        cutpoint: LegacyRestoreCutpoint,
        bootID: String
    ) -> Fixture {
        var result = stable(configuration: managed, bootID: bootID)
        result.legacyBackups = ["legacy-helper", "legacy-service", "legacy-meta"]
        result.journal = DurableJournal(
            source: managed,
            target: .configuration(managed),
            kind: .configurationChange,
            requirement: .reboot,
            preparedBootID: bootID,
            phase: .legacyRestoring
        )
        if cutpoint.rawOrder >= LegacyRestoreCutpoint.legacyHelperPublished.rawOrder {
            result.legacyHelper = true
        }
        if cutpoint.rawOrder >= LegacyRestoreCutpoint.legacyServicePublished.rawOrder {
            result.legacyService = true
        }
        if cutpoint.rawOrder >= LegacyRestoreCutpoint.configPublished.rawOrder {
            result.bootBlock = .exactLegacy
        }
        if cutpoint.rawOrder >= LegacyRestoreCutpoint.managedHelperDeleted.rawOrder {
            result.helper = false
        }
        if cutpoint.rawOrder >= LegacyRestoreCutpoint.managedDefaultsDeleted.rawOrder {
            result.defaultFile = false
            result.defaults = nil
        }
        if cutpoint.rawOrder >= LegacyRestoreCutpoint.managedServiceDeleted.rawOrder {
            result.service = false
        }
        if cutpoint.rawOrder >= LegacyRestoreCutpoint.helperBackupDeleted.rawOrder {
            result.legacyBackups.remove("legacy-helper")
        }
        if cutpoint.rawOrder >= LegacyRestoreCutpoint.serviceBackupDeleted.rawOrder {
            result.legacyBackups.remove("legacy-service")
        }
        if cutpoint.rawOrder >= LegacyRestoreCutpoint.metadataBackupDeleted.rawOrder {
            result.legacyBackups.remove("legacy-meta")
        }
        if cutpoint.rawOrder >= LegacyRestoreCutpoint.stateRetired.rawOrder {
            result.stateDirectory = false
            result.lock = false
            result.journal = nil
            result.removalTombstone = RemovalTombstone(
                contents: [.journal, .lock],
                integrity: .exact
            )
        }
        if cutpoint == .tombstoneJournalOnly {
            result.removalTombstone?.contents = [.journal]
        }
        if cutpoint == .tombstoneLockOnly {
            result.removalTombstone?.contents = [.lock]
        }
        if cutpoint == .tombstoneEmpty {
            result.removalTombstone?.contents = []
        }
        if cutpoint == .tombstoneRemoved {
            result.removalTombstone = nil
        }
        return result
    }

    static func discardingLegacy(
        managed: PWMFanConfiguration,
        cutpoint: LegacyDiscardCutpoint,
        bootID: String
    ) -> Fixture {
        var result = stable(configuration: managed, bootID: bootID)
        result.legacyBackups = ["legacy-helper", "legacy-service", "legacy-meta"]
        result.journal = DurableJournal(
            source: managed,
            target: .configuration(managed),
            kind: .configurationChange,
            requirement: .reboot,
            preparedBootID: bootID,
            phase: .legacyDiscarding
        )
        if cutpoint.rawOrder >= LegacyDiscardCutpoint.helperBackupDeleted.rawOrder {
            result.legacyBackups.remove("legacy-helper")
        }
        if cutpoint.rawOrder >= LegacyDiscardCutpoint.serviceBackupDeleted.rawOrder {
            result.legacyBackups.remove("legacy-service")
        }
        if cutpoint.rawOrder >= LegacyDiscardCutpoint.metadataBackupDeleted.rawOrder {
            result.legacyBackups.remove("legacy-meta")
        }
        if cutpoint == .journalDeleted {
            result.journal = nil
        }
        return result
    }

    mutating func boot(into bootID: String) {
        currentBootID = bootID
        liveConfiguration = journal?.target.configuration
    }

    mutating func beginFinalization() {
        journal?.phase = .finalizing
    }

    var recoveryActions: [PWMFanRecoveryAction] {
        guard let action = modeledRecoveryAction else { return [] }
        return [action]
    }

    mutating func retryOriginalOperation() {
        if journal == nil, integrity == .journalTemporary {
            integrity = .exact
            guard let target = intendedTarget?.configuration else { return }
            journal = DurableJournal(
                source: intendedSource,
                target: .configuration(target),
                kind: .configurationChange,
                requirement: intendedSource?.pin == target.pin
                    ? .reboot : .fullShutdown,
                preparedBootID: currentBootID,
                phase: .prepared
            )
            bootBlock = .managed(target)
            return
        }
        integrity = .exact
        if let action = modeledRecoveryAction {
            switch action {
            case .cancelPreparedChange:
                if let source = journal?.source {
                    convergeManaged(source)
                } else {
                    convergeAbsent()
                }
            case .completeRollbackPreparation:
                guard journal?.kind == .rollback,
                      let target = journal?.target else { return }
                bootBlock = target.configuration.map(BootBlock.managed) ?? .none
            case .finalizePreparedChange:
                if let target = journal?.target.configuration {
                    convergeManaged(target)
                } else if journal?.target.isUninstall == true {
                    convergeAbsent()
                }
            case .completeUninstall:
                convergeAbsent()
            case .completeLegacyConversion:
                guard let target = journal?.target.configuration else { return }
                convergeManaged(target)
                legacyBackups = ["legacy-helper", "legacy-service", "legacy-meta"]
            case .completeLegacyRestore:
                convergeLegacy()
            case .completeLegacyDiscard:
                let configuration = journal?.source ?? intendedSource
                if let configuration {
                    convergeManaged(configuration)
                    legacyBackups.removeAll()
                }
            case .completeManagedApply:
                break
            case .completeStateCleanup:
                removalTombstone = nil
            }
            return
        }
        if journal == nil,
           !stateDirectory || !lock || !helper || !defaultFile || !service,
           intendedTarget?.isUninstall == true {
            convergeAbsent()
        } else if journal == nil, case .exactLegacy = bootBlock {
            convergeLegacy()
        } else if journal == nil, let source = intendedSource {
            convergeManaged(source)
        }
    }

    func status() throws -> PWMFanStatus {
        if let removalTombstone,
           removalTombstone.integrity != .exact {
            throw HarnessDetectionError.unsafeTombstone
        }
        return try PWMFanProbeParser.parse(probe())
    }

    private var modeledRecoveryAction: PWMFanRecoveryAction? {
        if removalTombstone?.integrity == .exact {
            return .completeStateCleanup
        }
        guard let journal else { return nil }
        switch journal.phase {
        case .prepared:
            if journal.kind == .rollback,
               bootBlock.configuration == journal.source {
                return .completeRollbackPreparation
            }
            return bootBlock.configuration == journal.source
                ? .cancelPreparedChange : nil
        case .cancelling:
            return .cancelPreparedChange
        case .finalizing:
            return journal.kind == .uninstall
                ? .completeUninstall : .finalizePreparedChange
        case .legacyConverting:
            return .completeLegacyConversion
        case .legacyRestoring:
            return .completeLegacyRestore
        case .legacyDiscarding:
            return .completeLegacyDiscard
        }
    }

    private var hasIntegrityFailure: Bool {
        integrity != .exact
            || stagedState
            || removalTombstone != nil
            || (stateDirectory && !lock)
            || (!stateDirectory && (lock || helper || defaultFile || service))
            || managedFileState == "invalid"
    }

    private var managedFileState: String {
        if stagedState { return "invalid" }
        let assets = [helper, defaultFile, service]
        if stateDirectory && lock && assets.allSatisfy({ $0 }) { return "exact" }
        if !stateDirectory && !lock && assets.allSatisfy({ !$0 }) { return "none" }
        return "invalid"
    }

    private func probe() -> String {
        var values = V3Probe.values
        values["managed_files"] = managedFileState
        values["legacy"] = legacyProbeValue
        populateConfiguration(bootBlock.configuration, prefix: "disk", into: &values)
        switch bootBlock {
        case let .managed(configuration):
            values["disk_state"] = configuration.mode == .manual
                ? "managed_manual" : "managed_automatic"
        case .exactLegacy:
            values["disk_state"] = "external_pwm"
        case .none:
            values["disk_state"] = "none"
        }

        let topologyInvalid = liveConfiguration?.mode == .automatic
            && !automaticTopology.isValid
        if topologyInvalid {
            values["live_state"] = "invalid"
        } else {
            populateConfiguration(liveConfiguration, prefix: "live", into: &values)
            if let liveConfiguration {
                values["live_state"] = liveConfiguration.mode == .manual
                    ? "manual" : "automatic"
                if liveConfiguration.mode == .manual {
                    values["live_period"] = "40000"
                    values["live_enabled"] = "1"
                } else {
                    values["automatic_demand"] = "off"
                }
            }
        }

        if let journal {
            let isSameBoot = currentBootID == journal.preparedBootID
            values["transition"] = isSameBoot
                ? "prepared" : "bootedAwaitingConfirmation"
            values["journal_phase"] = journal.phase.rawValue
            values["transition_kind"] = switch journal.kind {
            case .configurationChange: "change"
            case .rollback: "rollback"
            case .uninstall: "uninstall"
            }
            values["transition_requirement"] = journal.requirement == .reboot
                ? "reboot" : "shutdown"
            populateConfiguration(journal.source, prefix: "source", into: &values)
            if journal.source == nil { values["source_state"] = "none" }
            if journal.target.isUninstall {
                values["target_state"] = "uninstalled"
            } else {
                populateConfiguration(
                    journal.target.configuration,
                    prefix: "target",
                    into: &values
                )
            }
            if let action = modeledRecoveryAction {
                values["recovery_action"] = action.rawValue
            }
        }

        if removalTombstone?.integrity == .exact {
            values["transition"] = "none"
            values["journal_phase"] = "removing"
            values["recovery_action"] = PWMFanRecoveryAction
                .completeStateCleanup.rawValue
            for key in [
                "transition_kind", "transition_requirement",
                "source_state", "source_pin", "source_duty",
                "source_temp", "source_hyst", "target_state",
                "target_pin", "target_duty", "target_temp", "target_hyst",
            ] {
                values[key] = ""
            }
        }

        let recovery = hasIntegrityFailure
            || (journal?.phase != .prepared && journal != nil)
            || modeledRecoveryAction != nil
        values["recovery"] = recovery ? "1" : "0"
        return V3Probe.render(values)
    }

    private var legacyProbeValue: String {
        if legacyHelper && legacyService, case .exactLegacy = bootBlock {
            return "exact"
        }
        if legacyBackups == ["legacy-helper", "legacy-service", "legacy-meta"] {
            return "backup"
        }
        return "none"
    }

    private func populateConfiguration(
        _ configuration: PWMFanConfiguration?,
        prefix: String,
        into values: inout [String: String]
    ) {
        guard let configuration else { return }
        values["\(prefix)_state"] = configuration.mode == .manual
            ? "manual" : "automatic"
        values["\(prefix)_pin"] = "\(configuration.pin.rawValue)"
        switch configuration {
        case let .manual(manual):
            values["\(prefix)_duty"] = "\(manual.dutyPercent)"
        case let .automatic(automatic):
            values["\(prefix)_temp"] = "\(automatic.turnOnCelsius)"
            values["\(prefix)_hyst"] = "\(automatic.hysteresisCelsius)"
        }
    }

    private mutating func convergeManaged(_ configuration: PWMFanConfiguration) {
        bootBlock = .managed(configuration)
        liveConfiguration = configuration
        defaults = configuration
        journal = nil
        stateDirectory = true
        stagedState = false
        removalTombstone = nil
        lock = true
        helper = true
        defaultFile = true
        service = true
        legacyHelper = false
        legacyService = false
    }

    private mutating func convergeAbsent() {
        bootBlock = .none
        liveConfiguration = nil
        defaults = nil
        journal = nil
        stateDirectory = false
        stagedState = false
        removalTombstone = nil
        lock = false
        helper = false
        defaultFile = false
        service = false
        legacyBackups.removeAll()
        legacyHelper = false
        legacyService = false
    }

    private mutating func convergeLegacy() {
        bootBlock = .exactLegacy
        liveConfiguration = .manual(.defaultConfiguration(pin: .gpio18))
        defaults = nil
        journal = nil
        stateDirectory = false
        stagedState = false
        removalTombstone = nil
        lock = false
        helper = false
        defaultFile = false
        service = false
        legacyBackups.removeAll()
        legacyHelper = true
        legacyService = true
    }
}

private enum V3Probe {
    static let order = [
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

    static let values: [String: String] = [
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

    static func render(_ values: [String: String]) -> String {
        "CASANATIVE_PWM_FAN_V3\n" + order.map {
            "\($0)\t\(values[$0]!)"
        }.joined(separator: "\n") + "\n"
    }
}

private extension UninstallCutpoint {
    var rawOrder: Int {
        UninstallCutpoint.allCases.firstIndex(of: self)!
    }
}

private extension LegacyConversionCutpoint {
    var rawOrder: Int {
        LegacyConversionCutpoint.allCases.firstIndex(of: self)!
    }
}

private extension LegacyRestoreCutpoint {
    var rawOrder: Int {
        LegacyRestoreCutpoint.allCases.firstIndex(of: self)!
    }
}

private extension LegacyDiscardCutpoint {
    var rawOrder: Int {
        LegacyDiscardCutpoint.allCases.firstIndex(of: self)!
    }
}
