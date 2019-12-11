using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.Group
{
    class RemoveEmptyFromDirectory : GroupAction
    {
        public override async Task Apply(State.Linked.LinkedGroup linkedGroup)
        {
            InProgress.Value = true;
            await AccountApi.Directory.ClassGroupManager.Delete(linkedGroup.Directory.Group).ConfigureAwait(false);
            // Data.Instance.SaveADGroupsToFile();
            InProgress.Value = false;
        }

        public RemoveEmptyFromDirectory() : base(
            "Lege Active Directory Klas Verwijderen",
            "Deze klas is leeg en bestaat enkel in Active Directory. " +
            "De klas kan verwijderd worden.",
            true)
        { }

        public static bool Evaluate(State.Linked.LinkedGroup group)
        {
            if (group.Directory.Linked && !group.Wisa.Linked && !group.Smartschool.Linked
                && !AccountApi.Directory.AccountManager.ContainsStudents(group.Directory.Group))
            {
                group.Actions.Add(new RemoveEmptyFromDirectory());
                return true;
            }
            return false;
        }
    }
}
