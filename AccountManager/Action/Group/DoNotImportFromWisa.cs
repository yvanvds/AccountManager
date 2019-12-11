using AbstractAccountApi;
using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.Group
{
    class DoNotImportFromWisa : GroupAction
    {

        public override async Task Apply(State.Linked.LinkedGroup linkedGroup)
        {
            InProgress.Value = true;
            AccountApi.Rules.DontImportClass rule = State.App.Instance.Wisa.AddimportRule(Rule.WI_DontImportClass) as AccountApi.Rules.DontImportClass;
            rule.SetConfig(0, linkedGroup.Wisa.Group.Name);
            await State.App.Instance.Wisa.Groups.Load().ConfigureAwait(false);
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


        public static bool Evaluate(State.Linked.LinkedGroup group)
        {
            if (group.Wisa.Linked && !group.Directory.Linked && !group.Smartschool.Linked)
            {
                group.Actions.Add(new DoNotImportFromWisa());
                return true;
            }
            return false;
        }
    }
}
