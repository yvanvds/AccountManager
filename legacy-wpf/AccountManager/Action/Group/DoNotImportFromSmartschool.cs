using System;
using System.Threading.Tasks;

namespace AccountManager.Action.Group
{
    class DoNotImportFromSmartschool : GroupAction
    {

        public override Task Apply(State.Linked.LinkedGroup linkedGroup)
        {
            throw new NotImplementedException();
        }

        public DoNotImportFromSmartschool() : base(
            "Klas Negeren",
            "Importeer deze klas niet uit Smartschool. Doe dit wanneer de klas moet bestaan in smartschool maar " +
            "niet gelinkt is aan een klas in Wisa.",
            true
            )
        {
        }

        public static bool Evaluate(State.Linked.LinkedGroup group)
        {
            if (!group.Wisa.Linked && group.Smartschool.Linked)
            {
                group.Actions.Add(new DoNotImportFromSmartschool());
                return true;
            }
            return false;
        }
    }
}
