using AbstractAccountApi;
using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class DoNotImportFromWisa : GroupAction
    {

        public override async Task Apply(LinkedGroup linkedGroup)
        {
            InProgress.Value = true;
            AccountApi.Rules.DontImportClass rule = Data.Instance.AddWisaImportRule(Rule.WI_DontImportClass) as AccountApi.Rules.DontImportClass;
            rule.SetConfig(0, linkedGroup.wisaGroup.Name);
            await Data.Instance.ReloadWisaClassgroups();
            InProgress.Value = false;
        }

        public DoNotImportFromWisa() : base(
            "Klas Negeren",
            "Een Wisa importregel toevoegen om deze groep te negeren. Doe dit als het nodig is dat de groep bestaat in WISA, " +
            "maar niet nodig is in Active Directory en Smartschool.",
            true
            )
        {

        }

    }
}
