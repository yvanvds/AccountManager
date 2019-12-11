using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.Group
{
    public class RemoveFromDirectory : GroupAction
    {
        public RemoveFromDirectory() : base(
            "Active Directory Klas Verwijderen",
            "Je kan deze klas niet verwijderen uit Active Directory omdat " +
            "ze niet leeg is. Verwijder of verplaats eerst de leerlingen in deze klas.",
            false)
        { }

        public override Task Apply(State.Linked.LinkedGroup linkedGroup)
        {
            throw new NotImplementedException();
        }

        public static bool Evaluate(State.Linked.LinkedGroup group)
        {
            if (group.Directory.Linked && !group.Wisa.Linked && !group.Smartschool.Linked
                && AccountApi.Directory.AccountManager.ContainsStudents(group.Directory.Group))
            {
                group.Actions.Add(new RemoveFromDirectory());
                return true;
            }
            return false;
        }
    }
}
