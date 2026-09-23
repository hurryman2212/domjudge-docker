<?php declare(strict_types=1);
/**
 * Generated from 'autoload.php.in' on Tue Sep 15 15:54:28 UTC 2026.
 *
 * Autoload setup file for the Symfony application
 *
 * Part of the DOMjudge Programming Contest Jury System and licensed
 * under the GNU GPL. See README and COPYING for details.
 */

use Doctrine\Common\Annotations\AnnotationRegistry;
use Composer\Autoload\ClassLoader;

// Load the static domserver file if we don't have the constants from it yet
if (!defined('VENDORDIR')) {
    require('/opt/domjudge/domserver/etc/domserver-static.php');
}

$loader = require VENDORDIR.'/autoload.php';
// The packaged vendor directory uses an authoritative class map.
$loader->addClassMap([
    App\Doctrine\ContestProblemOrderAssigner::class => dirname(__DIR__) . '/src/Doctrine/ContestProblemOrderAssigner.php',
]);
return $loader;
