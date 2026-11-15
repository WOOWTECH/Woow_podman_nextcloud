<?php
define('OC_CONSOLE', 1);
require '/var/www/html/lib/base.php';
set_exception_handler(function ($e) { fwrite(STDERR, get_class($e) . ': ' . $e->getMessage() . "\n"); exit(1); });
$coreVersion = \OCP\Server::get(\OCP\IConfig::class)->getSystemValue('version', '');
if (!preg_match('/^35\.0\.1(?:\.|$)/', $coreVersion)) {
    throw new RuntimeException('This repair was reviewed only for Nextcloud 35.0.1');
}
$db = \OCP\Server::get(\OCP\IDBConnection::class)->getInner();
if ($db->tableExists('federated_invites')) {
    echo json_encode(['already_present' => true]) . "\n";
    exit(0);
}
$ms = new \OC\DB\MigrationService('cloud_federation_api', $db, new \OC\Migration\NullOutput());
$instance = $ms->createInstance('1016Date202502262004');
$schema = $instance->changeSchema(new \OC\Migration\NullOutput(), fn() => new \OC\DB\SchemaWrapper($db), ['tablePrefix' => $db->getPrefix()]);
$source = $db->createSchema();
$target = $schema->getWrappedSchema();
$diff = $db->createSchemaManager()->createComparator()->compareSchemas($source, $target);
$sql = $db->getDatabasePlatform()->getAlterSchemaSQL($diff);
foreach ($sql as $statement) {
    $newConstraint = str_starts_with($statement, 'ALTER TABLE ' . $db->getPrefix() . 'federated_invites ADD CONSTRAINT ') && str_ends_with($statement, ' UNIQUE (token)');
    if ((!preg_match('/^CREATE (TABLE|UNIQUE INDEX|INDEX|SEQUENCE) /i', $statement) && !$newConstraint) || !str_contains($statement, 'federated_invites')) {
        throw new RuntimeException('Unexpected schema statement; no migration applied: ' . substr($statement, 0, 200));
    }
}
if (!$sql) throw new RuntimeException('Expected one missing table repair');
if (($argv[1] ?? '') !== '--apply') {
    echo json_encode(['preview' => true, 'sql' => $sql]) . "\n";
    exit(0);
}
$ms->executeStep('1016Date202502262004');
if (!$db->tableExists('federated_invites')) throw new RuntimeException('Official migration did not recreate the missing table');
echo json_encode(['passed' => true, 'official_migration_reexecuted' => 'cloud_federation_api/1016Date202502262004', 'only_missing_table_added' => true]) . "\n";
