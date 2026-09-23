<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260923060000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Add per-contest problem display order, preserving the existing label order.';
    }

    public function up(Schema $schema): void
    {
        $this->addSql("ALTER TABLE contestproblem ADD sortorder INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Display position of this problem within the contest'");

        // Let the database use the same collation as the previous shortname sort.
        $problems = $this->connection->fetchAllAssociative(
            'SELECT cid, probid FROM contestproblem ORDER BY cid, shortname, probid'
        );
        $previousContest = null;
        $position = 0;
        foreach ($problems as $problem) {
            if ($problem['cid'] !== $previousContest) {
                $previousContest = $problem['cid'];
                $position = 0;
            }
            $this->addSql(
                'UPDATE contestproblem SET sortorder = ? WHERE cid = ? AND probid = ?',
                [++$position, $problem['cid'], $problem['probid']]
            );
        }
    }

    public function down(Schema $schema): void
    {
        $this->addSql('ALTER TABLE contestproblem DROP sortorder');
    }

    public function isTransactional(): bool
    {
        return false;
    }
}
