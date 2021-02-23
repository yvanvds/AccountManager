using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.Group
{
    public static class GroupActionParser
    {
        public static void AddActions(State.Linked.LinkedGroup group)
        {
            group.OK = false;
            group.SetBasicFlags();

            if (group.Wisa.Group == null || group.Directory.Group == null || group.Smartschool.Group == null)
            {
                // these actions are needed when the account does not exist on one or more services
                DoNotImportFromWisa.Evaluate(group);
                AddToSmartschool.Evaluate(group);
                CreateInSmartschool.Evaluate(group);
                AddToDirectory.Evaluate(group);
                RemoveFromDirectory.Evaluate(group);
                RemoveEmptyFromDirectory.Evaluate(group);
                DoNotImportFromSmartschool.Evaluate(group);
            } else 
            {
                // if the account exists everywhere, we try these actions
                ModifySmartschoolData.Evaluate(group);
                AddADGroup.Evaluate(group);

                if (group.Actions.Count > 0)
                {
                    group.OK = false;
                } else
                {
                    group.OK = true;
                }
            }
        }
    }
}
