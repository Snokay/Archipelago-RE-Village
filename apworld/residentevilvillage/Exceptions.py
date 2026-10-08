class REVillageOptionError(Exception):
    """Levée quand une combinaison d'options n'est pas supportée (ex: option non
    implémentée pour cette version du world). Pattern repris de RE2ROptionError
    dans le world Resident Evil 2 Remake existant."""
    pass
