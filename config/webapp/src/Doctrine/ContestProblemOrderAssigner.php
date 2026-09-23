<?php declare(strict_types=1);

namespace App\Doctrine;

use App\Entity\ContestProblem;
use Doctrine\Bundle\DoctrineBundle\Attribute\AsEntityListener;
use Doctrine\ORM\EntityManagerInterface;
use Doctrine\ORM\Event\PrePersistEventArgs;
use Doctrine\ORM\Events;

#[AsEntityListener(event: Events::prePersist, entity: ContestProblem::class)]
class ContestProblemOrderAssigner
{
    public function __invoke(ContestProblem $problem, PrePersistEventArgs $args): void
    {
        // The contest editor may already have placed a new problem explicitly.
        if ($problem->getSortOrder() > 0) {
            return;
        }

        /** @var EntityManagerInterface $em */
        $em = $args->getObjectManager();
        $contest = $problem->getContest();
        $lastOrder = 0;
        if ($contest->getCid() !== null) {
            $lastOrder = (int)$em->getConnection()->fetchOne(
                'SELECT COALESCE(MAX(sortorder), 0) FROM contestproblem WHERE cid = ?',
                [$contest->getCid()]
            );
        }

        // A single import or new contest can persist several problems before flush.
        foreach ($em->getUnitOfWork()->getScheduledEntityInsertions() as $pending) {
            if ($pending instanceof ContestProblem && $pending->getContest() === $contest) {
                $lastOrder = max($lastOrder, $pending->getSortOrder());
            }
        }

        $problem->setSortOrder($lastOrder + 1);
    }
}
