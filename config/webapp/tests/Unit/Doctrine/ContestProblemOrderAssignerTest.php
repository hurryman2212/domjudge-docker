<?php declare(strict_types=1);

namespace App\Tests\Unit\Doctrine;

use App\Doctrine\ContestProblemOrderAssigner;
use App\Entity\Contest;
use App\Entity\ContestProblem;
use Doctrine\DBAL\Connection;
use Doctrine\ORM\EntityManagerInterface;
use Doctrine\ORM\Event\PrePersistEventArgs;
use Doctrine\ORM\UnitOfWork;
use PHPUnit\Framework\TestCase;

class ContestProblemOrderAssignerTest extends TestCase
{
    public function testAppendsAfterStoredAndPendingProblems(): void
    {
        $contest = $this->createMock(Contest::class);
        $contest->method('getCid')->willReturn(42);
        $pending = (new ContestProblem())->setContest($contest)->setSortOrder(8);
        $otherContest = (new ContestProblem())->setContest(new Contest())->setSortOrder(99);
        $problem = (new ContestProblem())->setContest($contest);

        $connection = $this->createMock(Connection::class);
        $connection->expects(self::once())->method('fetchOne')
            ->with('SELECT COALESCE(MAX(sortorder), 0) FROM contestproblem WHERE cid = ?', [42])
            ->willReturn('7');
        $unitOfWork = $this->createMock(UnitOfWork::class);
        $unitOfWork->method('getScheduledEntityInsertions')->willReturn([$pending, $otherContest]);
        $em = $this->createMock(EntityManagerInterface::class);
        $em->method('getConnection')->willReturn($connection);
        $em->method('getUnitOfWork')->willReturn($unitOfWork);

        (new ContestProblemOrderAssigner())($problem, new PrePersistEventArgs($problem, $em));

        self::assertSame(9, $problem->getSortOrder());
    }

    public function testNewContestUsesBatchInsertionOrder(): void
    {
        $contest = new Contest();
        $first = (new ContestProblem())->setContest($contest)->setShortname('Z');
        $second = (new ContestProblem())->setContest($contest)->setShortname('A');
        $unitOfWork = $this->createMock(UnitOfWork::class);
        $unitOfWork->method('getScheduledEntityInsertions')->willReturnOnConsecutiveCalls([], [$first]);
        $em = $this->createMock(EntityManagerInterface::class);
        $em->expects(self::never())->method('getConnection');
        $em->method('getUnitOfWork')->willReturn($unitOfWork);
        $assigner = new ContestProblemOrderAssigner();

        $assigner($first, new PrePersistEventArgs($first, $em));
        $assigner($second, new PrePersistEventArgs($second, $em));

        self::assertSame(1, $first->getSortOrder());
        self::assertSame(2, $second->getSortOrder());
    }

    public function testExplicitPositionIsPreserved(): void
    {
        $problem = (new ContestProblem())->setSortOrder(3);
        $em = $this->createMock(EntityManagerInterface::class);
        $em->expects(self::never())->method('getConnection');
        $em->expects(self::never())->method('getUnitOfWork');

        (new ContestProblemOrderAssigner())($problem, new PrePersistEventArgs($problem, $em));

        self::assertSame(3, $problem->getSortOrder());
    }
}
