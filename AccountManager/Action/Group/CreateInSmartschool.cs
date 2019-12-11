using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.Group
{
    class CreateInSmartschool : GroupAction
    {
        public override Task Apply(State.Linked.LinkedGroup linkedGroup)
        {
            throw new NotImplementedException();
        }

        public CreateInSmartschool() : base(
            "Lege Klas toevoegen aan Smartschool",
            "Als de klas niet meer nodig is in Wisa, kan je die manueel verwijderen. Je kan ook wachten tot de Wisa klas " +
            "leerlingen bevat.",
            false)
        {

        }

        public static bool Evaluate(State.Linked.LinkedGroup group)
        {
            if (group.Wisa.Linked && !group.Smartschool.Linked && !group.Wisa.Group.ContainsStudents())
            {
                group.Actions.Add(new CreateInSmartschool());
                return true;
            }
            return false;
        }
    }
}
